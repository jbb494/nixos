{ ffmpeg-headless
, lib
, makeWrapper
, python3
, stdenvNoCC
, v4l-utils
}:

# Webcam lighting fix served as a v4l2loopback virtual camera ("Clean Cam").
# See packages/clean-cam/clean_cam.py for what it does.
let
  python = python3.withPackages (ps: [ ps.numpy ps.opencv4 ]);
in
stdenvNoCC.mkDerivation {
  pname = "clean-cam";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./clean-cam;
    fileset = lib.fileset.unions [
      ./clean-cam/clean_cam.py
      # YuNet face detector (OpenCV Zoo, MIT), 2023mar release
      ./clean-cam/face_detection_yunet_2023mar.onnx
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/clean-cam $out/share/clean-cam $out/bin
    install -m 0555 $src/clean_cam.py $out/libexec/clean-cam/clean_cam.py
    install -m 0444 $src/face_detection_yunet_2023mar.onnx $out/share/clean-cam/
    makeWrapper ${python}/bin/python3 $out/bin/clean-cam \
      --add-flags "$out/libexec/clean-cam/clean_cam.py" \
      --set CLEAN_CAM_MODEL $out/share/clean-cam/face_detection_yunet_2023mar.onnx \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg-headless v4l-utils ]}
    runHook postInstall
  '';

  meta = {
    description = "Automatic webcam lighting correction as a virtual camera";
    platforms = lib.platforms.linux;
    license = lib.licenses.mit;
    mainProgram = "clean-cam";
  };
}
