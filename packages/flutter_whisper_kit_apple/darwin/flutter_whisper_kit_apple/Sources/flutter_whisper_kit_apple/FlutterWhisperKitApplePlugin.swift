import Foundation
import WhisperKit

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

/// Flutter WhisperKit Apple Plugin
///
/// This plugin provides WhisperKit functionality to Flutter applications on Apple platforms.
/// It handles model loading, audio transcription, and real-time recording capabilities.

private let transcriptionStreamChannelName = "flutter_whisper_kit/transcription_stream"
private let modelProgressStreamChannelName = "flutter_whisper_kit/model_progress_stream"

#if os(iOS)
private var flutterPluginRegistrar: FlutterPluginRegistrar?
#endif

/// Implementation of the WhisperKit API
///
/// This class handles all the core functionality of the plugin, including:
/// - Loading and managing WhisperKit models
/// - Transcribing audio from files
/// - Real-time audio recording and transcription
/// - Streaming transcription results back to Flutter
private class WhisperKitApiImpl: WhisperKitMessage {
  /// The WhisperKit instance used for transcription
  private var whisperKit: WhisperKit?
  
  /// Flag indicating if recording is currently active
  private var isRecording: Bool = false
  
  /// Task for handling real-time transcription
  private var transcriptionTask: Task<Void, Never>?
  
  /// Stream handler for sending transcription results to Flutter
  public static var transcriptionStreamHandler: TranscriptionStreamHandler?
  
  /// Stream handler for sending model download progress to Flutter
  public static var modelProgressStreamHandler: ModelProgressStreamHandler?

  /// Loads a WhisperKit model
  ///
  /// - Parameters:
  ///   - variant: The model variant to load (required)
  ///   - modelRepo: The repository to download the model from (optional)
  ///   - redownload: Whether to force redownload the model (required)
  ///   - completion: Callback with result of the operation
  func loadModel(
    variant: String?, modelRepo: String?, redownload: Bool,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let variant = variant else {
      completion(
        .failure(
          NSError(
            domain: "WhisperKitError", code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "Model variant is required"])))
      return
    }

    Task {
      do {
        // --- START OF DYNAMIC BUNDLED MODEL LOGIC ---
        // This logic dynamically checks if the requested model variant exists in the app bundle.
        
        if let bundledModelPath = Bundle.main.path(forResource: variant, ofType: nil) {
            // Found the model locally!
            print("✅ Found bundled model '\(variant)' at path: \(bundledModelPath). Loading it directly.")
            
            // Initialize WhisperKit directly from our local, bundled model path.
            // This completely bypasses any download or cache logic.
            self.whisperKit = try await WhisperKit(modelPath: bundledModelPath)
            
            // Immediately call completion with success.
            completion(.success(bundledModelPath))
            return // IMPORTANT: Exit the function to prevent fallback to download logic.
        } else {
            // Model not found in the bundle, proceed to the original download logic.
            print("⚠️ Bundled model '\(variant)' not found. Falling back to default download behavior.")
        }

        // --- END OF DYNAMIC BUNDLED MODEL LOGIC ---


        // -- ORIGINAL LOGIC (Now a fallback if a bundled model is not found) --
        if whisperKit == nil {
          let config = WhisperKitConfig(
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: false,
            download: false
          )
          whisperKit = try await WhisperKit(config)
        }

        guard let whisperKit = whisperKit else {
          throw NSError(
            domain: "WhisperKitError", code: 1002,
            userInfo: [
              NSLocalizedDescriptionKey: "Failed to initialize WhisperKit"
            ])
        }

        var modelFolder: URL?
        let localModels = await getLocalModels()
        let modelDirURL = getModelFolderPath()

        if localModels.contains(variant) && !redownload {
          modelFolder = modelDirURL.appendingPathComponent(variant)
        } else {
          let downloadDestination = modelDirURL.appendingPathComponent(variant)

          if !FileManager.default.fileExists(atPath: downloadDestination.path) {
            try FileManager.default.createDirectory(
              at: downloadDestination, withIntermediateDirectories: true, attributes: nil)
          }

          do {
            modelFolder = try await WhisperKit.download(
              variant: variant,
              from: modelRepo ?? "argmaxinc/whisperkit-coreml",
              progressCallback:  { progress in
                if let streamHandler = WhisperKitApiImpl.modelProgressStreamHandler as? ModelProgressStreamHandler {
                  streamHandler.sendProgress(progress)
                }
              },
            )
            // Save the downloaded model folder to the specified model directory
            if let downloadedFolder = modelFolder {
              // Ensure the model directory exists
              if !FileManager.default.fileExists(atPath: modelDirURL.path) {
                try FileManager.default.createDirectory(
                  at: modelDirURL, withIntermediateDirectories: true, attributes: nil)
              }
              
              if downloadedFolder.path != modelDirURL.appendingPathComponent(variant).path {
                let targetFolder = modelDirURL.appendingPathComponent(variant)
                
                if FileManager.default.fileExists(atPath: targetFolder.path) {
                  try FileManager.default.removeItem(at: targetFolder)
                }
                
                try FileManager.default.copyItem(at: downloadedFolder, to: targetFolder)
                
                modelFolder = targetFolder
              }
            }
          } catch {
            print("Download error: \(error.localizedDescription)")
            throw NSError(
              domain: "WhisperKitError", code: 1005,
              userInfo: [
                NSLocalizedDescriptionKey: "Failed to download model: \(error.localizedDescription)"
              ])
          }
        }

        if let folder = modelFolder {
          whisperKit.modelFolder = folder

          try await whisperKit.prewarmModels()
          
          try await whisperKit.loadModels()
          
          completion(.success(folder.path))
        } else {
          throw NSError(
            domain: "WhisperKitError", code: 1003,
            userInfo: [
              NSLocalizedDescriptionKey: "Failed to get model folder"
            ])
        }
      } catch {
        print("LoadModel error: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }

  // --- NO OTHER CHANGES ARE NEEDED BELOW THIS LINE ---
  // The rest of the file remains identical to the original.

  /// Transcribes audio from a file
  ///
  /// - Parameters:
  ///   - filePath: Path to the audio file to transcribe
  ///   - options: Transcription options
  ///   - completion: Callback with result of the transcription
  func transcribeFromFile(
    filePath: String, options: [String: Any?],
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let whisperKit = whisperKit else {
      completion(
        .failure(
          NSError(
            domain: "WhisperKitError", code: 2001,
            userInfo: [
              NSLocalizedDescriptionKey:
                "WhisperKit instance not initialized. Call loadModel first."
            ])))
      return
    }

    Task {
      do {
        let resolvedPath: String
        #if os(iOS)
        if filePath.hasPrefix("assets/") {
          guard let path = resolveAssetPath(assetPath: filePath) else {
            throw NSError(
              domain: "WhisperKitError", code: 4002,
              userInfo: [NSLocalizedDescriptionKey: "Could not resolve asset path: \(filePath)"])
          }
          resolvedPath = path
        } else {
          resolvedPath = filePath
        }
        #else
        resolvedPath = filePath
        #endif
        
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
          throw NSError(
            domain: "WhisperKitError", code: 4002,
            userInfo: [NSLocalizedDescriptionKey: "Audio file does not exist at path: \(resolvedPath)"])
        }

        guard FileManager.default.isReadableFile(atPath: resolvedPath) else {
          throw NSError(
            domain: "WhisperKitError", code: 4003,
            userInfo: [
              NSLocalizedDescriptionKey: "No read permission for audio file at path: \(resolvedPath)"
            ])
        }

        Logging.debug("Loading audio file: \(resolvedPath)")
        let loadingStart = Date()
        let audioFileSamples = try await Task {
          try autoreleasepool {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: resolvedPath)
          }
        }.value
        Logging.debug("Loaded audio file in \(Date().timeIntervalSince(loadingStart)) seconds")

        let decodingOptions = try DecodingOptions.fromJson(options)

        let transcription: TranscriptionResult? = try await transcribeAudioSamples(
          audioFileSamples,
          options: decodingOptions,
        )

        guard let transcription = transcription else {
          throw NSError(
            domain: "WhisperKitError", code: 2004,
            userInfo: [NSLocalizedDescriptionKey: "Transcription result is nil"])
        }
        let transcriptionDict = transcription.toJson()

        do {
          let jsonData = try JSONSerialization.data(withJSONObject: transcriptionDict, options: [])
          guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(
              domain: "WhisperKitError", code: 2003,
              userInfo: [
                NSLocalizedDescriptionKey: "Failed to create JSON string from transcription result"
              ])
          }
          completion(.success(jsonString))
        } catch {
          throw NSError(
            domain: "WhisperKitError", code: 2002,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Failed to serialize transcription result: \(error.localizedDescription)"
            ])
        }

      } catch {
        completion(.failure(error))
      }
    }
  }

  func transcribeAudioSamples(_ samples: [Float], options: DecodingOptions?) async throws
    -> TranscriptionResult?
  {
    guard let whisperKit = whisperKit else { return nil }
    var selectedLanguage: String = "japanese"
    let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
    let task: DecodingTask = .transcribe
    var lastConfirmedSegmentEndSeconds: Float = 0
    let seekClip: [Float] = [lastConfirmedSegmentEndSeconds]

    let options =
      options
      ?? DecodingOptions(
        verbose: true,
        task: task,
        language: languageCode,
        temperature: Float(0),
        temperatureFallbackCount: Int(5),
        sampleLength: Int(224),
        usePrefillPrompt: true,
        usePrefillCache: true,
        skipSpecialTokens: true,
        withoutTimestamps: false,
        wordTimestamps: true,
        clipTimestamps: seekClip,
        concurrentWorkerCount: Int(4),
        chunkingStrategy: .vad
      )

    let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
      audioArray: samples,
      decodeOptions: options
    )

    let mergedResults = mergeTranscriptionResults(transcriptionResults)

    return mergedResults
  }

  private func getModelFolderPath() -> URL {
    if let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      return appSupport.appendingPathComponent("WhisperKitModels")
    }

    return getDocumentsDirectory().appendingPathComponent("WhisperKitModels")
  }

  private func getDocumentsDirectory() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  private func getLocalModels() async -> [String] {
    let modelPath = getModelFolderPath()
    var localModels: [String] = []

    do {
      if FileManager.default.fileExists(atPath: modelPath.path) {
        let contents = try FileManager.default.contentsOfDirectory(atPath: modelPath.path)
        localModels = contents
      }
    } catch {
      print("Error checking local models: \(error.localizedDescription)")
    }

    return WhisperKit.formatModelFiles(localModels)
  }
  
  func fetchAvailableModels(
    modelRepo: String, matching: [String], token: String?,
    completion: @escaping (Result<[String?], Error>) -> Void
  ) {
    Task {
      do {
        
        let models = try await WhisperKit.fetchAvailableModels(
          from: modelRepo,
          matching: matching,
          token: token
        )
        
        completion(.success(models))
      } catch {
        print("Error fetching available models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func recommendedModels(completion: @escaping (Result<String?, Error>) -> Void) {
    Task {
      do {
        let modelSupport = WhisperKit.recommendedModels()
        
        let modelSupportDict: [String: Any] = [
          "default": modelSupport.default,
          "supported": modelSupport.supported,
          "disabled": modelSupport.disabled
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: modelSupportDict, options: [])
        let jsonString = String(data: jsonData, encoding: .utf8)
        
        completion(.success(jsonString))
      } catch {
        print("Error getting recommended models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func deviceName(completion: @escaping (Result<String, Error>) -> Void) {
    Task {
      do {
        let deviceName = WhisperKit.deviceName()
        completion(.success(deviceName))
      } catch {
        print("Error getting device name: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func formatModelFiles(
    modelFiles: [String],
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    let formattedFiles = WhisperKit.formatModelFiles(modelFiles)
    completion(.success(formattedFiles))
  }
  
  func detectLanguage(
    audioPath: String,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        guard let whisperKit = whisperKit else {
          throw NSError(
            domain: "WhisperKitError", code: 1002,
            userInfo: [
              NSLocalizedDescriptionKey: "WhisperKit instance not initialized. Call loadModel first."
            ])
        }
        
        let result = try await whisperKit.detectLanguage(audioPath: audioPath)
        
        let resultDict: [String: Any] = [
          "language": result.language,
          "probabilities": result.langProbs
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: resultDict, options: [])
        let jsonString = String(data: jsonData, encoding: .utf8)
        
        completion(.success(jsonString))
      } catch {
        print("Error detecting language: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func fetchModelSupportConfig(
    repo: String, downloadBase: String?, token: String?,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        let downloadBaseURL = downloadBase != nil ? URL(string: downloadBase!) : nil
        
        let config = try await WhisperKit.fetchModelSupportConfig(
          from: repo,
          downloadBase: downloadBaseURL,
          token: token
        )
        
        let jsonData = try JSONSerialization.data(withJSONObject: config.toJson(), options: [])
        let jsonString = String(data: jsonData, encoding: .utf8)
        
        completion(.success(jsonString))
      } catch {
        print("Error fetching model support config: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func recommendedRemoteModels(
    repo: String, downloadBase: String?, token: String?,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        let downloadBaseURL = downloadBase != nil ? URL(string: downloadBase!) : nil
        
        let modelSupport = try await WhisperKit.recommendedRemoteModels(
          from: repo,
          downloadBase: downloadBaseURL,
          token: token
        )
        
        let jsonData = try JSONSerialization.data(withJSONObject: modelSupport.toJson(), options: [])
        let jsonString = String(data: jsonData, encoding: .utf8)
        
        completion(.success(jsonString))
      } catch {
        print("Error fetching recommended remote models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func setupModels(
    model: String?, downloadBase: String?, modelRepo: String?,
    modelToken: String?, modelFolder: String?, download: Bool,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        guard let whisperKit = whisperKit else {
          throw NSError(
            domain: "WhisperKitError", code: 3001,
            userInfo: [NSLocalizedDescriptionKey: "WhisperKit instance not initialized."])
        }
        
        let downloadBaseURL = downloadBase != nil ? URL(string: downloadBase!) : nil
        let modelFolderURL = modelFolder != nil ? URL(fileURLWithPath: modelFolder!) : nil
        
        try await whisperKit.setupModels(
          model: model,
          downloadBase: downloadBaseURL,
          modelRepo: modelRepo,
          modelToken: modelToken,
          modelFolder: modelFolderURL?.path,
          download: download
        )
        
        completion(.success("Models set up successfully"))
      } catch {
        print("Error setting up models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func download(
    variant: String, downloadBase: String?, useBackgroundSession: Bool,
    repo: String, token: String?,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        let downloadBaseURL = downloadBase != nil ? URL(string: downloadBase!) : nil
        
        let downloadURL = try await WhisperKit.download(
          variant: variant,
          downloadBase: downloadBaseURL,
          useBackgroundSession: useBackgroundSession,
          from: repo,
          token: token,
          progressCallback: { [weak self] progress in
            if let modelProgressHandler = WhisperKitApiImpl.modelProgressStreamHandler as? ModelProgressStreamHandler {
              modelProgressHandler.sendProgress(progress)
            }
          }
        )
        
        completion(.success(downloadURL.path))
      } catch {
        print("Error downloading model: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func prewarmModels(
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        guard let whisperKit = whisperKit else {
          throw NSError(
            domain: "WhisperKitError", code: 3001,
            userInfo: [NSLocalizedDescriptionKey: "WhisperKit instance not initialized. Call loadModel first."])
        }
        
        try await whisperKit.prewarmModels()
        
        completion(.success("Models prewarmed successfully"))
      } catch {
        print("Error prewarming models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func unloadModels(
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    Task {
      do {
        guard let whisperKit = whisperKit else {
          throw NSError(
            domain: "WhisperKitError", code: 3001,
            userInfo: [NSLocalizedDescriptionKey: "WhisperKit instance not initialized. Call loadModel first."])
        }
        
        await whisperKit.unloadModels()
        
        completion(.success("Models unloaded successfully"))
      } catch {
        print("Error unloading models: \(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }
  
  func clearState(
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    do {
      guard let whisperKit = whisperKit else {
        throw NSError(
          domain: "WhisperKitError", code: 3001,
          userInfo: [NSLocalizedDescriptionKey: "WhisperKit instance not initialized. Call loadModel first."])
      }
      
      whisperKit.clearState()
      
      completion(.success("State cleared successfully"))
    } catch {
      print("Error clearing state: \(error.localizedDescription)")
      completion(.failure(error))
    }
  }
  
  func loggingCallback(
    level: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      guard let whisperKit = whisperKit else {
        throw NSError(
          domain: "WhisperKitError", code: 3001,
          userInfo: [NSLocalizedDescriptionKey: "WhisperKit instance not initialized. Call loadModel first."])
      }
      
      whisperKit.loggingCallback { message in
        print("WhisperKitLog: \(message)")
      }
      
      completion(.success(()))
    } catch {
      print("Error setting logging callback: \(error.localizedDescription)")
      completion(.failure(error))
    }
  }
  
  func startRecording(
    options: [String: Any?], loop: Bool,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let whisperKit = whisperKit else {
      completion(
        .failure(
          NSError(
            domain: "WhisperKitError", code: 3001,
            userInfo: [
              NSLocalizedDescriptionKey:
                "WhisperKit instance not initialized. Call loadModel first."
            ])))
      return
    }
    
    if whisperKit.audioProcessor == nil {
      whisperKit.audioProcessor = AudioProcessor()
    }
    
    Task(priority: .userInitiated) {
      do {
        guard await AudioProcessor.requestRecordPermission() else {
          throw NSError(
            domain: "WhisperKitError", code: 3002,
            userInfo: [NSLocalizedDescriptionKey: "Microphone access was not granted."])
        }
        
        var deviceId: DeviceID?
        
        try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: deviceId) { _ in
        }
        
        isRecording = true
        
        if loop {
          self.startRealtimeLoop(options: options)
        }
        
        completion(.success("Recording started successfully"))
      } catch {
        completion(.failure(error))
      }
    }
  }
  
  func stopRecording(
    loop: Bool, completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let whisperKit = whisperKit else {
      completion(
        .failure(
          NSError(
            domain: "WhisperKitError", code: 3001,
            userInfo: [
              NSLocalizedDescriptionKey:
                "WhisperKit instance not initialized. Call loadModel first."
            ])))
      return
    }
    
    isRecording = false
    stopRealtimeTranscription()
    whisperKit.audioProcessor.stopRecording()
    
    if !loop {
      Task {
        do {
          _ = try await transcribeCurrentBufferInternal(options: [:])
          completion(.success("Recording stopped and transcription completed"))
        } catch {
          completion(.failure(error))
        }
      }
    } else {
      completion(.success("Recording stopped"))
    }
  }
  
  private func startRealtimeLoop(options: [String: Any?]) {
    transcriptionTask = Task {
      var lastTranscribedText = ""
      
      while isRecording && !Task.isCancelled {
        do {
          if let result = try await transcribeCurrentBufferInternal(options: options) {
            if result.text != lastTranscribedText {
              lastTranscribedText = result.text
              
              if let streamHandler = WhisperKitApiImpl.transcriptionStreamHandler as? TranscriptionStreamHandler {
                streamHandler.sendTranscription(result)
              }
            }
          }
          
          try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
          print("Realtime transcription error: \(error.localizedDescription)")
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }
      
      if let streamHandler = WhisperKitApiImpl.transcriptionStreamHandler as? TranscriptionStreamHandler {
        streamHandler.sendTranscription(nil)
      }
    }
  }
  
  private func stopRealtimeTranscription() {
    transcriptionTask?.cancel()
    transcriptionTask = nil
  }
  
  private func transcribeCurrentBufferInternal(options: [String: Any?]) async throws -> TranscriptionResult? {
    guard let whisperKit = whisperKit else { return nil }
    
    let currentBuffer = whisperKit.audioProcessor.audioSamples
    
    let bufferSeconds = Float(currentBuffer.count) / Float(WhisperKit.sampleRate)
    guard bufferSeconds > 1.0 else {
      throw NSError(
        domain: "WhisperKitError", code: 3003,
        userInfo: [NSLocalizedDescriptionKey: "Not enough audio data for transcription"])
    }
    
    let decodingOptions = try DecodingOptions.fromJson(options)
    
    let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
      audioArray: Array(currentBuffer),
      decodeOptions: decodingOptions
    )
    
    return mergeTranscriptionResults(transcriptionResults)
  }
  
  private func mergeTranscriptionResults(_ results: [TranscriptionResult]) -> TranscriptionResult? {
    guard !results.isEmpty else { return nil }
    
    if results.count == 1 {
      return results[0]
    }
    
    var mergedText = ""
    var mergedSegments: [TranscriptionSegment] = []
    
    for result in results {
      mergedText += result.text
      mergedSegments.append(contentsOf: result.segments)
    }
    
    return TranscriptionResult(
      text: mergedText,
      segments: mergedSegments,
      language: results[0].language,
      timings: results[0].timings,
      seekTime: results[0].seekTime
    )
  }
}

private class TranscriptionStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
  
  func sendTranscription(_ result: TranscriptionResult?) {
    if let eventSink = eventSink {
      DispatchQueue.main.async {
        if let result = result {
          let resultDict = result.toJson()
          do {
            let jsonData = try JSONSerialization.data(withJSONObject: resultDict, options: [])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
              eventSink(jsonString)
            } else {
              print("Error: Failed to convert JSON data to string.")
              eventSink(FlutterError(code: "JSON_CONVERSION_ERROR", message: "Failed to convert JSON data to string.", details: nil))
            }
          } catch {
            print("Error: JSON serialization failed with error: \(error.localizedDescription)")
            eventSink(FlutterError(code: "JSON_SERIALIZATION_ERROR", message: "JSON serialization failed.", details: error.localizedDescription))
          }
        } else {
          eventSink("")
        }
      }
    }
  }
}

private class ModelProgressStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
  
  func sendProgress(_ progress: Progress) {
    if let eventSink = eventSink {
      DispatchQueue.main.async {
        let progressDict: [String: Any] = [
          "totalUnitCount": progress.totalUnitCount,
          "completedUnitCount": progress.completedUnitCount,
          "fractionCompleted": progress.fractionCompleted,
          "isIndeterminate": progress.isIndeterminate,
          "isPaused": progress.isPaused,
          "isCancelled": progress.isCancelled
        ]
        eventSink(progressDict)
      }
    }
  }
}

public class FlutterWhisperKitApplePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
      flutterPluginRegistrar = registrar
    #elseif os(macOS)
      let messenger = registrar.messenger
    #else
      #error("Unsupported platform.")
    #endif

    let streamHandler = TranscriptionStreamHandler()
    WhisperKitApiImpl.transcriptionStreamHandler = streamHandler
    
    let modelProgressHandler = ModelProgressStreamHandler()
    WhisperKitApiImpl.modelProgressStreamHandler = modelProgressHandler
    
    WhisperKitMessageSetup.setUp(binaryMessenger: messenger, api: WhisperKitApiImpl())
    
    let transcriptionChannel = FlutterEventChannel(name: transcriptionStreamChannelName, binaryMessenger: messenger)
    transcriptionChannel.setStreamHandler(streamHandler)
    
    let modelProgressChannel = FlutterEventChannel(name: modelProgressStreamChannelName, binaryMessenger: messenger)
    modelProgressChannel.setStreamHandler(modelProgressHandler)
  }
}

#if os(iOS)
private func resolveAssetPath(assetPath: String) -> String? {
  guard let registrar = flutterPluginRegistrar else {
    print("Error: Flutter plugin registrar not available")
    return nil
  }
  
  let key1 = registrar.lookupKey(forAsset: assetPath)
  if let path1 = Bundle.main.path(forResource: key1, ofType: nil) {
    return path1
  }
  
  let assetName = assetPath.hasPrefix("assets/") ? String(assetPath.dropFirst(7)) : assetPath
  let key2 = registrar.lookupKey(forAsset: assetName)
  if let path2 = Bundle.main.path(forResource: key2, ofType: nil) {
    return path2
  }
  
  if let path3 = Bundle.main.path(forResource: assetName.split(separator: ".").first?.description, ofType: assetName.split(separator: ".").last?.description) {
    return path3
  }
  
  let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
  let filePath = "\(documentsPath)/\(assetName)"
  if FileManager.default.fileExists(atPath: filePath) {
    return filePath
  }
  
  if let resourcePath = Bundle.main.resourcePath {
    let possiblePaths = [
      "\(resourcePath)/\(assetName)",
      "\(resourcePath)/flutter_assets/\(assetName)",
      "\(resourcePath)/Frameworks/App.framework/flutter_assets/\(assetName)"
    ]
    
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
  }
  
  print("Error: Could not find asset at path: \(assetPath)")
  print("Debug: Available resources in main bundle: \(Bundle.main.paths(forResourcesOfType: nil, inDirectory: nil))")
  return nil
}
#endif
