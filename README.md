This is a README.md file

private func setupNowPlaying() {
    do {
        try OPNowPlayingInfoCenter.shared.configureNowPlaying(commandHandler: handleRemoteCommand(_:event:), interruptionHandler: handleInterruption(_:))
        try OPNowPlayingInfoCenter.shared.configureNowPlayingAudioSessionBegin()
    } catch {
        Logger.debug("Error configuring Now Playing Info Center: \(error.localizedDescription)")
    }
}

private func handleRemoteCommand(_ remoteCommand: OPNowPlayingInfoCenter.RemoteCommand, event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    switch remoteCommand {
    case .pause:
        pause()
    case .play:
        play()
    case .stop:
        stop()
    case .togglePausePlay:
        isPlaying ? pause() : play()
    case .nextTrack:
        nextTrack()
    case .previousTrack:
        previousTrack()
    case .changePlaybackPosition:
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
        }
        
        player.currentPlayerManager.seek(toTime: event.positionTime) { completed in
            
        }
    default:
        break
    }
    
    return .success
}

private func handleInterruption(_ interruption: OPNowPlayingInfoCenter.Interruption) {
    switch interruption {
    case .began:
        pause()
    case .ended(let shouldPlay):
        if shouldPlay {
            play()
        }
    case .failed(let error):
        presentingError = error
        stop()
    }
}

let nowPlayingInfo = OPNowPlayingInfoCenter.StaticInfo(mediaType: isVideoMode ? .video : .audio, title: track.title, artist: track.subtitle)

OPNowPlayingInfoCenter.shared.setupNowPlayingInfo(nowPlayingInfo)
OPNowPlayingInfoCenter.shared.updateNowPlaying(assetURL: url, artwork: thumbnail)
