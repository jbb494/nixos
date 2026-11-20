"""clean-cam: automatic, halo-free lighting correction for a webcam,
served as a virtual camera.

Everything here is global or a very soft whole-frame ramp: there is no
cut-out around the person, so nothing can create a halo when you move.

Per frame:
  1. YuNet (tiny ONNX face detector, OpenCV DNN, CPU) finds the face.
  2. Cheek pixels give the skin level and the left/right side-light slope
     (log Y = a + b*u, robust fit; beard, glasses and nose shadow excluded).
  3. Exposure: one gain for the whole frame, metered on the face, capped so the
     brightest part of the face stays below ~75%; smoothed with a dead band.
  4. Shadows: edge-aware local shadow lift (like a photo editor's "Shadows"
     slider). A guided filter gives each pixel's local light level; dark areas
     are lifted, bright ones left alone. It is recomputed from each frame alone
     and its edges follow real image edges at full resolution, so it cannot lag
     or halo. How much to lift is set (globally) by how harsh the side light on
     the face is.
  5. White balance: referenced on the skin (orange walls / blue windows can't
     fool it), partial and slow.
  6. Highlight roll-off LUT so nothing hard-clips.

Modes:
  serve   Feed a v4l2loopback device. The real webcam is only opened while
          some other process has the loopback device open (Discord etc.),
          otherwise a 2 fps placeholder keeps the device visible.
  preview Show the result in a window (ffplay); --compare puts original|result.
"""

import argparse
import os
import signal
import subprocess
import sys
import time

import cv2
import numpy as np

W, H, FPS = 1280, 720, 30
SW, SH = 320, 180  # analysis resolution (also the face detector's input)


def log(*a):
    print("clean-cam:", *a, file=sys.stderr, flush=True)


def ema(old, new, k):
    return old + k * (new - old)


class Relighter:
    def __init__(self, model, strength=0.6, target=0.46, wb_strength=0.55):
        self.det = cv2.FaceDetectorYN.create(model, "", (SW, SH), 0.6, 0.3, 1)
        self.strength = strength          # side-light evening, 0..1
        self.target = target              # wanted skin luminance, 0..1
        self.wb_strength = wb_strength    # 0 = trust the camera, 1 = force skin to target hue
        self.n = 0
        self.face = None                  # YuNet box + 5 landmarks, in SW x SH px
        self.slow = None                  # slowly tracked (cx, half_width) for the ramp
        self.last_seen = 0.0
        self.presence = 0.0               # 0..1, fades face-driven corrections in/out
        self.skin_level = 0.0
        self.slope = 0.0                  # smoothed side-light slope b
        self.expo = 1.0
        self.wb = np.ones(3, np.float32)  # B, G, R multipliers
        self.gx, self.gy = np.meshgrid(np.arange(SW, dtype=np.float32) + 0.5,
                                       np.arange(SH, dtype=np.float32) + 0.5)
        self.xs_full = (np.arange(W, dtype=np.float32) + 0.5) * (SW / W)
        # highlight roll-off, indexed by (pixel * gain * 4) as a 12-bit value
        i = np.arange(4096, dtype=np.float32) / (4 * 255)
        knee = 0.82
        o = np.where(i > knee, knee + (1 - knee) * (1 - np.exp(-(i - knee) / (1 - knee))), i)
        self.lut = np.clip(o * 255 + 0.5, 0, 255).astype(np.uint8)

    # -- face -------------------------------------------------------------
    def _update_face(self, small, now):
        if self.n % 2 == 0:
            _, faces = self.det.detect(small)
            if faces is not None and len(faces):
                f = max(faces, key=lambda r: r[2] * r[3])[:14].astype(np.float32)
                self.face = f if self.face is None or self.presence < 0.05 else ema(self.face, f, 0.5)
                c = np.array([f[0] + f[2] / 2, f[2] / 2], np.float32)
                self.slow = c if self.slow is None or self.presence < 0.05 else ema(self.slow, c, 0.06)
                self.last_seen = now
        self.n += 1
        visible = self.face is not None and now - self.last_seen < 1.5
        self.presence = ema(self.presence, 1.0 if visible else 0.0, 0.1 if visible else 0.03)

    def _cheeks(self, Y):
        """Cheek samples located from the landmarks (colour-independent)."""
        rex, rey, lex, ley, nx, ny = self.face[4:10]
        ed = max(abs(lex - rex), 1.0)
        eye_y = (rey + ley) / 2
        return ((self.gx > min(rex, lex) - 0.45 * ed) & (self.gx < max(rex, lex) + 0.45 * ed) &
                (np.abs(self.gx - nx) > 0.28 * ed) &
                (self.gy > eye_y + 0.40 * ed) & (self.gy < ny + 0.02 * ed) &
                (Y > 0.03) & (Y < 0.97))

    @staticmethod
    def _guided_coeffs(I, r=6, eps=0.008):
        """Self-guided filter (He et al.) coefficients: base = A*I + B is an
        edge-preserving smooth of I. Computed at low res, applied at full res."""
        k = (2 * r + 1, 2 * r + 1)
        m = cv2.boxFilter(I, -1, k)
        v = cv2.boxFilter(I * I, -1, k) - m * m
        a = v / (v + eps)
        b = m - a * m
        return cv2.boxFilter(a, -1, k), cv2.boxFilter(b, -1, k)

    def shadow_amount(self):
        """Global lift strength: a little always, more when the face is side-lit."""
        side = min(abs(self.slope), 1.2) / 1.2 * self.presence
        return 0.2 + self.strength * 0.85 * side

    # -- per frame --------------------------------------------------------
    def process(self, frame):
        now = time.monotonic()
        small = cv2.resize(frame, (SW, SH), interpolation=cv2.INTER_AREA)
        self._update_face(small, now)
        Y = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32) * (1 / 255) + 1e-3

        if self.face is not None and self.presence > 0.05:
            x, y, w, h = self.face[0:4]
            u = (self.gx - (x + w / 2)) / (w / 2)
            sel = self._cheeks(Y)
            if sel.sum() >= 30:
                fit = self._fit(np.log(Y[sel]), u[sel])
                if fit is not None:
                    a, b, inl = fit
                    self.slope = ema(self.slope, b, 0.05)
                    level = float(np.exp(a))
                    self.skin_level = level if self.skin_level == 0 else ema(self.skin_level, level, 0.1)
                    bgr = small[sel][inl].astype(np.float32).mean(0) + 1
                    gr = np.clip((1.30 * bgr[1] / bgr[2]) ** self.wb_strength, 0.8, 1.3)
                    gb = np.clip((0.82 * bgr[1] / bgr[0]) ** self.wb_strength, 0.8, 1.3)
                    wb = np.array([gb, 1.0, gr], np.float32)
                    wb /= wb @ [0.114, 0.587, 0.299]       # keep brightness
                    self.wb = ema(self.wb, wb, 0.04)
            if self.skin_level > 0:
                # brightest part of the face must stay below ~75%
                box = (np.abs(u) < 0.85) & (self.gy > y) & (self.gy < y + h)
                hl = float(np.percentile(Y[box], 93)) if box.sum() > 20 else 0.75
                want = float(np.clip(min(self.target / self.skin_level, 0.75 / max(hl, 0.05)), 0.6, 1.9))
                if abs(want / self.expo - 1) > 0.05:            # dead band: no pumping
                    self.expo = ema(self.expo, want, 0.06)
        else:
            # nobody there: plain centre-weighted exposure, colour back to the camera's
            want = float(np.clip(0.42 / float(np.mean(Y[SH // 4: 3 * SH // 4, SW // 4: 3 * SW // 4])), 0.7, 1.6))
            if abs(want / self.expo - 1) > 0.05:
                self.expo = ema(self.expo, want, 0.03)
            self.wb = ema(self.wb, np.ones(3, np.float32), 0.01)

        # local shadow lift: base light level per pixel (edge-aware), gain = (pivot/base)^s below pivot
        A, B = self._guided_coeffs(Y)
        Yf = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32) * (self.expo / 255)
        base = cv2.resize(A, (W, H)) * Yf + cv2.resize(B, (W, H)) * self.expo
        s, pivot = self.shadow_amount(), 0.55
        lift = np.power(pivot / np.clip(base, 0.10, pivot), s)          # 1 above the pivot
        g = cv2.multiply(lift, 4 * self.expo)
        G3 = cv2.merge([g * self.wb[0], g * self.wb[1], g * self.wb[2]])
        idx = cv2.multiply(frame, G3, dtype=cv2.CV_16U)
        np.minimum(idx, 4095, out=idx)
        return self.lut[idx]

    @staticmethod
    def _fit(logy, u):
        A = np.stack([np.ones_like(u), u], 1)
        inl = np.ones(len(u), bool)
        coef = None
        for _ in range(3):  # robust re-fits drop beard, glasses and specular outliers
            if inl.sum() < 10:
                return None
            try:
                coef, *_ = np.linalg.lstsq(A[inl], logy[inl], rcond=None)
            except np.linalg.LinAlgError:
                return None
            res = logy - A @ coef
            s = 1.4826 * np.median(np.abs(res[inl])) + 0.02
            inl = np.abs(res) < 2.0 * s
        return float(coef[0]), float(np.clip(coef[1], -1.5, 1.5)), inl


def camera_setup(dev):
    """Neutral, highlight-friendly camera settings; the relighter does the rest.
    Exposure stays on the camera's auto mode: in manual mode this sensor loses its
    internal gain (30 fps manual exposure is ~10x darker than auto)."""
    ctrls = dict(brightness=0, contrast=50, gamma=300, gain=64, sharpness=50,
                 backlight_compensation=0, white_balance_automatic=1,
                 exposure_dynamic_framerate=0, auto_exposure=3)
    arg = ",".join(f"{k}={v}" for k, v in ctrls.items())
    subprocess.run(["v4l2-ctl", "-d", dev, f"--set-ctrl={arg}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------------------

def open_camera(dev):
    cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_FPS, FPS)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    if not cap.isOpened():
        return None
    return cap


def read_frame(cap):
    ok, frame = cap.read()
    if not ok:
        return None
    if frame.shape[1] != W or frame.shape[0] != H:
        frame = cv2.resize(frame, (W, H))
    return frame


def consumers(device, exclude):
    """PIDs (other than ours/our ffmpeg) holding the loopback device open."""
    target = os.path.realpath(device)
    found = set()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) in exclude:
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    if os.readlink(f"{fd_dir}/{fd}") == target:
                        found.add(int(pid))
                        break
                except OSError:
                    pass
        except OSError:
            pass
    return found


class DeviceWatch:
    """inotify on the loopback device: wakes us the instant any process opens or
    closes it, so the real webcam is grabbed/released without polling delays."""

    IN_OPEN, IN_CLOSE = 0x20, 0x08 | 0x10

    def __init__(self, path):
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0 or libc.inotify_add_watch(self.fd, path.encode(), self.IN_OPEN | self.IN_CLOSE) < 0:
            raise OSError(ctypes.get_errno(), "inotify on " + path)

    def changed(self):
        try:
            return len(os.read(self.fd, 4096)) > 0
        except BlockingIOError:
            return False


def placeholder():
    img = np.full((H, W, 3), 24, np.uint8)
    cv2.putText(img, "camera starting...", (W // 2 - 190, H // 2), cv2.FONT_HERSHEY_SIMPLEX,
                1.2, (140, 140, 140), 2, cv2.LINE_AA)
    return img


def serve(args):
    while not os.path.exists(args.output):      # v4l2loopback not loaded yet
        log(f"waiting for {args.output} (is the v4l2loopback module loaded?)")
        time.sleep(5)
    relight = Relighter(args.model, args.strength, args.target)
    sink = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24",
         "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
         "-f", "v4l2", "-pix_fmt", "yuv420p", args.output],
        stdin=subprocess.PIPE)
    exclude = {os.getpid(), sink.pid}
    idle = placeholder()
    cap = None
    # The webcam is on exactly while another process has Clean Cam open: inotify
    # reports every open/close of the device instantly, then /proc says who holds it.
    watch = DeviceWatch(args.output)
    watch.changed()                                      # drop our own ffmpeg's open
    users, last_scan, retry_at = set(), 0.0, 0.0
    log(f"serving {args.input} -> {args.output}")
    try:
        while sink.poll() is None:
            now = time.monotonic()
            if watch.changed() or now - last_scan > 2.0:
                last_scan = now
                users = consumers(args.output, exclude)
            active = bool(users)
            if active and cap is None and now >= retry_at:
                cap = open_camera(args.input)
                if cap:
                    camera_setup(args.input)
                    log("consumer connected, camera on")
                else:
                    log("could not open camera (in use by another app?)")
                    retry_at = now + 3
            elif not active and cap is not None:
                cap.release()
                cap = None
                log("no consumers, camera off")

            if cap is not None:
                frame = read_frame(cap)
                if frame is None:                   # camera busy or unplugged
                    cap.release()
                    cap = None
                    retry_at = now + 3
                    log("camera read failed, retrying in 3 s")
                    continue
                out = frame if args.bypass else relight.process(frame)
            else:
                out = idle
                time.sleep(0.1)
            sink.stdin.write(out.tobytes())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        if cap is not None:
            cap.release()
        sink.kill()


def preview(args):
    relight = Relighter(args.model, args.strength, args.target)
    cap = open_camera(args.input)
    if cap is None:
        sys.exit("could not open camera (in use?)")
    camera_setup(args.input)
    ow = W * 2 if args.compare else W
    player = subprocess.Popen(
        ["ffplay", "-loglevel", "error", "-window_title", "clean-cam preview",
         "-fflags", "nobuffer", "-f", "rawvideo", "-pixel_format", "bgr24",
         "-video_size", f"{ow}x{H}", "-framerate", str(FPS), "-i", "-"],
        stdin=subprocess.PIPE)
    t_proc, n, last_snap = 0.0, 0, 0.0
    try:
        while player.poll() is None:
            frame = read_frame(cap)
            if frame is None:
                break
            t0 = time.perf_counter()
            out = relight.process(frame)
            t_proc += time.perf_counter() - t0
            n += 1
            if args.compare:
                out = np.hstack([frame, out])
            if args.snapshot and time.monotonic() - last_snap > 0.5:
                last_snap = time.monotonic()
                cv2.imwrite(args.snapshot + ".tmp.jpg", out)
                os.replace(args.snapshot + ".tmp.jpg", args.snapshot)
            if n % 150 == 0:
                log(f"avg processing {1000 * t_proc / n:.1f} ms/frame, "
                    f"expo={relight.expo:.2f} skin={relight.skin_level:.2f} slope={relight.slope:.2f} lift={relight.shadow_amount():.2f} wb={np.round(relight.wb, 2)}")
            player.stdin.write(out.tobytes())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        cap.release()
        player.kill()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["serve", "preview"])
    p.add_argument("--input", default="/dev/video0")
    p.add_argument("--output", default="/dev/video10")
    p.add_argument("--model", default=os.environ.get("CLEAN_CAM_MODEL", ""))
    p.add_argument("--strength", type=float, default=0.6, help="side-light evening, 0..1")
    p.add_argument("--target", type=float, default=0.46, help="face brightness, 0..1")
    p.add_argument("--compare", action="store_true", help="preview: side by side")
    p.add_argument("--snapshot", help="preview: write a jpg here twice a second")
    p.add_argument("--bypass", action="store_true", help="serve: pass frames through untouched")
    args = p.parse_args()
    if not args.model:
        sys.exit("--model (or CLEAN_CAM_MODEL) is required")
    cv2.setNumThreads(1)  # idle OpenCV worker threads spin; one per stage is plenty
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    (serve if args.mode == "serve" else preview)(args)


if __name__ == "__main__":
    main()
