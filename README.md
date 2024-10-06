## Bambu Lab Live Stream for ReactPlayer on Windows
# Setup
For the correct configuration file you need to install the BambuSlicer: https://github.com/bambulab/BambuStudio
Then follow the steps under https://wiki.bambulab.com/en/software/bambu-studio/virtual-camera to activate the live view at least once. 
This will create an `url.txt` file in the folder `%USERPROFILE%\AppData\Roaming\BambuStudio\cameratools`.
This file *has* to be copied into the root directory of this project and replaces the empty dummy file. 

From time to time the content of the `url.txt` file need to be updated. An automatic update is a future idea but I haven't figured out the required endpoint yet. Should be burried in the slicer code: https://github.com/bambulab/BambuStudio

A manual update is still simple enough. Just disable and enable the live view in the slicer again. This should generate a new `url.txt` file in the user profile folder which you can then copy to the root of this project again.
# Start Stream
Just execute the `start_streaming.bat` file. You can close the main window afterwards.
# Stop Stream
Like starting, just run the `stop_streaming.bat` file.
# Check Current Status
Evaluate the current running status with the `check_instances.bat` file.
# ReactPlayer Example
```
<ReactPlayer
    url="http://127.0.0.1:8090/hls/stream.m3u8"
    playing
    controls
/>
```
## Optional: Using `hls.js` for better browser support
Some browsers may not support HLS natively. Use `hls.js` to enable HLS playback across all modern browsers.
### Steps:
1. Install hls.js:
```bash
    npm install hls.js
```
2. Implement the Player Component with `hls.js`:
```jsx
    import React, { useRef, useEffect } from 'react';
    import Hls from 'hls.js';

    function HLSPlayer() {
    const videoRef = useRef(null);

    useEffect(() => {
        if (Hls.isSupported()) {
        const hls = new Hls({
            lowLatencyMode: true,
            liveSyncDuration: 2, // Adjust as needed
        });
        hls.loadSource('http://127.0.0.1:8090/hls/stream.m3u8');
        hls.attachMedia(videoRef.current);
        } else if (videoRef.current.canPlayType('application/vnd.apple.mpegurl')) {
        videoRef.current.src = '"http://127.0.0.1:8090/hls/stream.m3u8"';
        } else {
        console.error('This browser does not support HLS.');
        }
    }, []);

    return <video ref={videoRef} controls />;
    }

    export default HLSPlayer;
```
3. Update Your App Component:
```jsx
    import React from 'react';
    import HLSPlayer from './HLSPlayer';

    function App() {
    return (
        <div className="App">
        <HLSPlayer />
        </div>
    );
    }

    export default App;
```

# Leftovers from the `cameratools`
Unused but still in the project:
- ffmpeg.cfg
- ffmpeg.sdp
