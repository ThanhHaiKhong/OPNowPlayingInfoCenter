// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Combine
import MediaPlayer

public class OPNowPlayingInfoCenter: NSObject {
    
    // MARK: - Typealias
    
    public typealias RemoteCommandResult = (RemoteCommand, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    public typealias RemoteCommandEvent = (RemoteCommand, MPRemoteCommandEvent)
    public typealias InterruptionResult = (Interruption) -> Void
    
    // MARK: - Share Instance
    
    public static let shared = OPNowPlayingInfoCenter()
    
    // MARK: - Public Properties
    
    public var defaultAllowsExternalPlayback: Bool {
        return true
    }
    public var defaultRegisteredCommands: [RemoteCommand] {
        return [.togglePausePlay, .play, .pause, .nextTrack, .previousTrack, .changePlaybackPosition]
    }
    public var defaultDisabledCommands: [RemoteCommand] {
        return []
    }
    
    // MARK: - Private Properties
    
    private var interruptionObserver: NSObjectProtocol!
    private var interruptionHandler: (Interruption) -> Void = { _ in }
    private let remoteCommandPublisher = Publisher()
    private var subscriptions = Set<AnyCancellable>()
    
    // MAKR: - Init
    
    override private init() {
        super.init()
        
    }
    
    // MARK: - Deinit
    
    deinit {
        if let interruptionObserver = interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
}

// MARK: - Public Methods

public extension OPNowPlayingInfoCenter {
    
    func handleNowPlayableConfiguration(commands: [RemoteCommand] = RemoteCommand.defaultDisabledCommands,
                                        disabledCommands: [RemoteCommand] = RemoteCommand.defaultDisabledCommands,
                                        commandHandler: @escaping RemoteCommandResult,
                                        interruptionHandler: @escaping InterruptionResult) throws {
        self.interruptionHandler = interruptionHandler
        
        // Use the default behavior for registering commands.
        try configureRemoteCommands(commands,
                                    disabledCommands: disabledCommands,
                                    commandHandler: commandHandler)
    }
    
    func handleNowPlayableSessionStart() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                      object: audioSession,
                                                                      queue: .main) { [unowned self] notification in
            self.handleAudioSessionInterruption(notification: notification)
        }
        
        try audioSession.setCategory(.playback, mode: .default, options: [.allowAirPlay, .defaultToSpeaker, .mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        try audioSession.setActive(true)
    }
    
    func handleNowPlayableSessionEnd() {
        // Stop observing interruptions to the audio session.
        interruptionObserver = nil
        
        // Make the audio session inactive.
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session, error: \(error)")
        }
    }
    
    func setupNowPlayingInfo(_ info: StaticInfo) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPNowPlayingInfoPropertyAssetURL] = info.assetURL
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = info.mediaType.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = info.isLiveStream
        nowPlayingInfo[MPMediaItemPropertyTitle] = info.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = info.artist
        nowPlayingInfo[MPMediaItemPropertyArtwork] = info.artwork
        nowPlayingInfo[MPMediaItemPropertyAlbumArtist] = info.albumArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = info.albumTitle
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateNowPlayingInfo(_ info: DynamicInfo) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = info.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = info.position
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = info.rate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        nowPlayingInfo[MPNowPlayingInfoPropertyCurrentLanguageOptions] = info.currentLanguageOptions
        nowPlayingInfo[MPNowPlayingInfoPropertyAvailableLanguageOptions] = info.availableLanguageOptionGroups
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    func updateNowPlaying(artwork: UIImage) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        let image = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        nowPlayingInfo[MPMediaItemPropertyArtwork] = image
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
}

// MARK: - Private Methods

private extension OPNowPlayingInfoCenter {
    
    func configureRemoteCommands(_ commands: [RemoteCommand],
                                 disabledCommands: [RemoteCommand],
                                 commandHandler: @escaping RemoteCommandResult) throws {
        guard commands.count > 1 else { throw ConfigurationError.noRegisteredCommands }
        
        for command in RemoteCommand.allCases {
            // Remove any existing handler.
            command.removeHandler()
            
            // Add a handler if necessary.
            if commands.contains(command) {
                command.addHandler(commandHandler)
            }
            
            // Disable the command if necessary.
            command.setDisabled(disabledCommands.contains(command))
        }
    }
    
    func configureRemoteCommand(_ commands: [RemoteCommand],
                                disabledCommands: [RemoteCommand]) throws {
        guard commands.count > 1 else { throw ConfigurationError.noRegisteredCommands }
        
        for command in RemoteCommand.allCases {
            // Remove any existing handler.
            command.removeHandler()
            
            // Add a handler if necessary.
            if commands.contains(command) {
                command.addTargetPublisher()
                    .sink { [unowned self] event in
                        self.remoteCommandPublisher.send(event)
                    }
                    .store(in: &subscriptions)
            }
            
            // Disable the command if necessary.
            command.setDisabled(disabledCommands.contains(command))
        }
    }
    
    func handleAudioSessionInterruption(notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let interruptionTypeUInt = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeUInt)
        else {
            return
        }
        
        switch interruptionType {
        case .began:
            interruptionHandler(.began)
        case .ended:
            do {
                // When an interruption ends, determine whether playback should resume automatically, and reactivate the audio session if necessary.
                try AVAudioSession.sharedInstance().setActive(true)
                var shouldResume = false
                
                if let optionsUInt = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: optionsUInt).contains(.shouldResume) {
                    shouldResume = true
                }
                
                interruptionHandler(.ended(shouldResume))
            } catch {
                // When the audio session cannot be resumed after an interruption, invoke the handler with error information.
                interruptionHandler(.failed(error))
            }
        @unknown default:
            break
        }
    }
}

// MARK: - RemoteCommand

extension OPNowPlayingInfoCenter {
    
    public enum RemoteCommand: CaseIterable {
        case pause, play, stop, togglePausePlay
        case nextTrack, previousTrack, changeRepeatMode, changeShuffleMode
        case changePlaybackRate, seekBackward, seekForward, skipBackward, skipForward, changePlaybackPosition
        case rating, like, dislike
        case bookmark
        case enableLanguageOption, disableLanguageOption
        
        public var remoteCommand: MPRemoteCommand {
            let remoteCommandCenter = MPRemoteCommandCenter.shared()
            
            switch self {
            case .pause:
                return remoteCommandCenter.pauseCommand
            case .play:
                return remoteCommandCenter.playCommand
            case .stop:
                return remoteCommandCenter.stopCommand
            case .togglePausePlay:
                return remoteCommandCenter.togglePlayPauseCommand
            case .nextTrack:
                return remoteCommandCenter.nextTrackCommand
            case .previousTrack:
                return remoteCommandCenter.previousTrackCommand
            case .changeRepeatMode:
                return remoteCommandCenter.changeRepeatModeCommand
            case .changeShuffleMode:
                return remoteCommandCenter.changeShuffleModeCommand
            case .changePlaybackRate:
                return remoteCommandCenter.changePlaybackRateCommand
            case .seekBackward:
                return remoteCommandCenter.seekBackwardCommand
            case .seekForward:
                return remoteCommandCenter.seekForwardCommand
            case .skipBackward:
                return remoteCommandCenter.skipBackwardCommand
            case .skipForward:
                return remoteCommandCenter.skipForwardCommand
            case .changePlaybackPosition:
                return remoteCommandCenter.changePlaybackPositionCommand
            case .rating:
                return remoteCommandCenter.ratingCommand
            case .like:
                return remoteCommandCenter.likeCommand
            case .dislike:
                return remoteCommandCenter.dislikeCommand
            case .bookmark:
                return remoteCommandCenter.bookmarkCommand
            case .enableLanguageOption:
                return remoteCommandCenter.enableLanguageOptionCommand
            case .disableLanguageOption:
                return remoteCommandCenter.disableLanguageOptionCommand
            }
        }
        
        public func removeHandler() {
            remoteCommand.removeTarget(nil)
        }
        
        public func addHandler(_ handler: @escaping RemoteCommandResult) {
            switch self {
            case .skipBackward:
                MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [15.0]
            case .skipForward:
                MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [15.0]
            default:
                break
            }
            
            remoteCommand.addTarget { handler(self, $0) }
        }
        
        public func addTargetPublisher() -> AnyPublisher<RemoteCommandEvent, Never> {
            switch self {
            case .skipBackward:
                MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [15.0]
            case .skipForward:
                MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [15.0]
            default:
                break
            }
            
            return Future<RemoteCommandEvent, Never> { promise in
                remoteCommand.addTarget { event in
                    if self == .changePlaybackPosition {
                        guard event is MPChangePlaybackPositionCommandEvent else {
                            return .commandFailed
                        }
                    }
                    
                    let remoteEvent = (self, event)
                    promise(.success(remoteEvent))
                    
                    return .success
                }
            }
            .eraseToAnyPublisher()
        }
        
        public func setDisabled(_ isDisabled: Bool) {
            remoteCommand.isEnabled = !isDisabled
        }
        
        public static var defaultRegisteredCommands: [RemoteCommand] {
            return [.togglePausePlay, .play, .pause, .nextTrack, .previousTrack, .changePlaybackPosition]
        }
        
        public static var defaultDisabledCommands: [RemoteCommand] {
            return []
        }
    }
}

// MARK: - Extension `RemoteCommand` conform to `Hashable`

extension OPNowPlayingInfoCenter.RemoteCommand: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: self))
    }
}

// MARK: - Extension `RemoteCommand` conform to `Equatable`

extension OPNowPlayingInfoCenter.RemoteCommand: Equatable {
    
    public static func == (lhs: OPNowPlayingInfoCenter.RemoteCommand, rhs: OPNowPlayingInfoCenter.RemoteCommand) -> Bool {
        return String(describing: lhs) == String(describing: rhs)
    }
}

// MARK: - Extension `RemoteCommand` conform to `Identifiable`

extension OPNowPlayingInfoCenter.RemoteCommand: Identifiable {
    
    public var id: String {
        return String(describing: self)
    }
}

// MARK: - Extension `RemoteCommand` conform to `CustomStringConvertible`

extension OPNowPlayingInfoCenter.RemoteCommand: CustomStringConvertible {
    
    public var description: String {
        switch self {
        case .pause:
            return "Pause"
        case .play:
            return "Play"
        case .stop:
            return "Stop"
        case .togglePausePlay:
            return "Toggle Pause/Play"
        case .nextTrack:
            return "Next Track"
        case .previousTrack:
            return "Previous Track"
        case .changeRepeatMode:
            return "Change Repeat Mode"
        case .changeShuffleMode:
            return "Change Shuffle Mode"
        case .changePlaybackRate:
            return "Change Playback Rate"
        case .seekBackward:
            return "Seek Backward"
        case .seekForward:
            return "Seek Forward"
        case .skipBackward:
            return "Skip Backward"
        case .skipForward:
            return "Skip Forward"
        case .changePlaybackPosition:
            return "Change Playback Position"
        case .rating:
            return "Rating"
        case .like:
            return "Like"
        case .dislike:
            return "Dislike"
        case .bookmark:
            return "Bookmark"
        case .enableLanguageOption:
            return "Enable Language Option"
        case .disableLanguageOption:
            return "Disable Language Option"
        }
    }
}

// MARK: - Extension `RemoteCommand` conform to `Sendable`

extension OPNowPlayingInfoCenter.RemoteCommand: Sendable {
    
}

// MARK: - ConfigurationError

extension OPNowPlayingInfoCenter {
    
    public enum ConfigurationError: LocalizedError {
        case noRegisteredCommands
        case cannotSetCategory(Error)
        case cannotActivateSession(Error)
        case cannotReactivateSession(Error)
        
        public var errorDescription: String? {
            switch self {
            case .noRegisteredCommands:
                return "At least one remote command must be registered."
            case .cannotSetCategory(let error):
                return "The audio session category could not be set:\n\(error)"
            case .cannotActivateSession(let error):
                return "The audio session could not be activated:\n\(error)"
            case .cannotReactivateSession(let error):
                return "The audio session could not be resumed after interruption:\n\(error)"
            }
        }
    }
}

// MARK: - StaticInfo

extension OPNowPlayingInfoCenter {
    
    public struct StaticInfo {
        
        public let assetURL: URL
        public let mediaType: MPNowPlayingInfoMediaType
        public let isLiveStream: Bool
        
        public let title: String
        public let artist: String?
        public let artwork: MPMediaItemArtwork?
        
        public let albumArtist: String?
        public let albumTitle: String?
        
        public init(assetURL: URL,
                    mediaType: MPNowPlayingInfoMediaType,
                    isLiveStream: Bool = false,
                    title: String,
                    artist: String? = nil,
                    artwork: UIImage? = nil,
                    albumArtist: String? = nil,
                    albumTitle: String? = nil) {
            self.assetURL = assetURL
            self.mediaType = mediaType
            self.isLiveStream = isLiveStream
            self.title = title
            self.artist = artist
            self.albumArtist = albumArtist
            self.albumTitle = albumTitle
            
            var mediaArtwork: MPMediaItemArtwork?
            
            if let image = artwork {
                mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            
            self.artwork = mediaArtwork
        }
    }
}

// MARK: - DynamicInfo

extension OPNowPlayingInfoCenter {
    
    public struct DynamicInfo {
        
        public let rate: Float
        public let position: Float
        public let duration: Float
        
        public let currentLanguageOptions: [MPNowPlayingInfoLanguageOption]
        public let availableLanguageOptionGroups: [MPNowPlayingInfoLanguageOptionGroup]
        
        public init(rate: Float,
                    position: Float,
                    duration: Float,
                    currentLanguageOptions: [MPNowPlayingInfoLanguageOption] = [],
                    availableLanguageOptionGroups: [MPNowPlayingInfoLanguageOptionGroup] = []) {
            self.rate = rate
            self.position = position
            self.duration = duration
            self.currentLanguageOptions = currentLanguageOptions
            self.availableLanguageOptionGroups = availableLanguageOptionGroups
        }
    }
}

// MARK: - Interruption

extension OPNowPlayingInfoCenter {
    
    public enum Interruption {
        case began, ended(Bool), failed(Error)
    }
}

// MARK: - HandleType

extension OPNowPlayingInfoCenter {
    
    public enum HandleType {
        case remoteCommand
        case interruption
    }
}

// MARK: - Publisher

extension OPNowPlayingInfoCenter {
    
    public class Publisher: Combine.Publisher {
        public typealias Output = RemoteCommandEvent
        public typealias Failure = Never
        
        private var subscribers = [AnySubscriber<Output, Failure>]()
        
        public func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
            let subscription = Subscription(subscriber: subscriber)
            subscribers.append(AnySubscriber(subscriber))
            subscriber.receive(subscription: subscription)
        }
        
        public func send(_ value: Output) {
            for subscriber in subscribers {
                _ = subscriber.receive(value)
            }
        }
        
        public func send(completion: Subscribers.Completion<Failure>) {
            for subscriber in subscribers {
                subscriber.receive(completion: completion)
            }
        }
    }
}

// MARK: - Subscription

extension OPNowPlayingInfoCenter {
    
    public class Subscription<S: Subscriber>: Combine.Subscription where S.Input == RemoteCommandEvent, S.Failure == Never {
        private var subscriber: S?
        
        public init(subscriber: S) {
            self.subscriber = subscriber
        }
        
        public func request(_ demand: Subscribers.Demand) {
            // Handle demand if needed
        }
        
        public func cancel() {
            subscriber = nil
        }
    }
}
