VirtualCamera tweak for iOS 17. Replaces the camera's image/video output with an arbitrary image or video file.

This works by hooking into `mediaserverd`, which is responsible for, among other things, connecting to the camera hardware and forwarding image data to interested clients (such as user-installed apps). VCam works in apps even if they don't have tweak injection

This is a POC stage. The filepath to the "replacement media" is hardcoded `image_utils.m`. Memory leaks kill `mediaserverd` every 30s
