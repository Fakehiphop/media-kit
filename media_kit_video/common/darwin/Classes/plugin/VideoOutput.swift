import CoreGraphics
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// Closing the gate waits for an in-progress GL resize/render to finish. No
// platform dispatch or mpv property access is permitted inside runIfEnabled.
final class VideoOutputRenderGate {
  private let lock = NSLock()
  private var enabled = true

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    lock.unlock()
  }

  @discardableResult
  func runIfEnabled(_ body: () -> Void) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard enabled else { return false }
    body()
    return true
  }
}

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  // Read on the platform thread only after initializationCompletion.
  private(set) var usesHardwareAcceleration = false
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false
  private let renderGate = VideoOutputRenderGate()
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    initializationCompletion: @escaping (Bool) -> Void = { _ in }
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    #if canImport(UIKit)
      // PiliPlus-同构：不在退后台时关闭渲染闸门。
      // 上游 media_kit 从无此闸门，PiliPlus 用的就是上游版本，后台照样出帧；
      // 关闭闸门会让 textureFrameAvailable 停止，PiP 永远停在最后一帧。
      // 这里只在回到前台时补一次刷新，闸门恒为开启。
      renderGate.setEnabled(true)
      lifecycleObservers = [
        NotificationCenter.default.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          self?.renderGate.setEnabled(true)
          self?.updateCallback()
        },
      ]
    #endif

    worker.enqueue {
      self._init(completion: initializationCompletion)
    }
  }

  deinit {
    lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      guard !self.disposed else { return }
      self.width = width
      self.height = height
    }
  }

  public func dispose(completion: @escaping () -> Void) {
    // Drain rendering on its worker without blocking the platform thread,
    // which pending render jobs may still need for texture notifications.
    worker.enqueue {
      self.disposed = true
      self.texture?.dispose()
      self.disposeTextureId {
        self.worker.cancel()
        completion()
      }
    }
  }

  private func _init(completion: @escaping (Bool) -> Void) {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    let update: () -> Void = { [weak self] in
      self?.updateCallback()
    }
    var hardwareTexture: ResizableTextureProtocol?
    if enableHardwareAcceleration {
      #if canImport(UIKit)
        // PiliPlus-同构：上游在此不做 applicationState 前置判断。保留主线程
        // 创建（GL 上下文需要平台线程），但不再因"当前不在前台"而放弃硬件
        // 纹理——否则后台重建输出会静默降级、或直接无纹理可用。
        DispatchQueue.main.sync {
          renderGate.runIfEnabled {
            hardwareTexture = TextureHW(handle: handle, updateCallback: update)
          }
        }
      #else
        hardwareTexture = TextureHW(handle: handle, updateCallback: update)
      #endif
    }
    if let hardwareTexture = hardwareTexture {
      usesHardwareAcceleration = true
      texture = SafeResizableTexture(hardwareTexture)
    } else {
      if enableHardwareAcceleration {
        NSLog("VideoOutput: hardware rendering unavailable; using software rendering")
      }
      guard let softwareTexture = TextureSW(handle: handle, updateCallback: update) else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      texture = SafeResizableTexture(softwareTexture)
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
      completion(true)
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId(completion: @escaping () -> Void = {}) {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      if textureId_ >= 0 {
        registry_.unregisterTexture(textureId_)
      }
      completion()
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    guard !disposed, texture != nil else { return }
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    let resized = currentSize != size
    let render = {
      if resized {
        self.currentSize = size
        self.texture.resize(size)
      }
      self.texture.render(size)
    }
    if usesHardwareAcceleration {
      // The main-thread resign-active handler waits for this short GL section.
      // Keep all main.sync notifications and mpv property reads outside it.
      guard renderGate.runIfEnabled(render) else { return }
    } else {
      render()
    }
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      if resized {
        that.textureUpdateCallback(that.textureId, size)
      }
      // Textures must be marked as available from the main thread.
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
