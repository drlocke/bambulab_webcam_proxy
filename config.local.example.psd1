@{
    DeploymentMode = 'Legacy'

    # Preferred when the printer model exposes RTSP/RTSPS. Keep this file local
    # because the URL contains the printer access code.
    PrinterStreamUrl = 'rtsps://bblp:ACCESS_CODE@PRINTER_IP/streaming/live/1'

    # Multi-account mode uses the unsupported Bambu cloud API and installed
    # CameraTools. Generate a unique secret with the command in the setup guide.
    # DeploymentMode = 'Multi'
    # BambuRegion = 'us'
    # MultiSessionSecret = 'REPLACE_WITH_A_RANDOM_SECRET'
    # SecureCookies = $true
}