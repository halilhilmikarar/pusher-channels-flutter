import Flutter
import Foundation
import PusherSwift
import UIKit

public class SwiftPusherChannelsFlutterPlugin: NSObject, FlutterPlugin, PusherDelegate, Authorizer {
  private var pusher: Pusher!
  public var methodChannel: FlutterMethodChannel!

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwiftPusherChannelsFlutterPlugin()
    instance.methodChannel = FlutterMethodChannel(name: "pusher_channels_flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      initChannels(call: call, result: result)
    case "connect":
      connect(result: result)
    case "disconnect":
      disconnect(result: result)
    case "getSocketId":
      getSocketId(result: result)
    case "subscribe":
      subscribe(call: call, result: result)
    case "unsubscribe":
      unsubscribe(call: call, result: result)
    case "trigger":
      trigger(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func initChannels(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pusher != nil {
      pusher.disconnect()
    }

    let args = call.arguments as! [String: Any]

    // --- Auth method (endpoint / custom authorizer) + optional headers ---
    var authMethod: AuthMethod = .noMethod
    if let endpoint = args["authEndpoint"] as? String {
      if let headers = args["authHeaders"] as? [String: String] {
        // PusherSwift: endpoint + request customizer (header ekleme)
        authMethod = .endpoint(
          authEndpoint: endpoint,
          authRequestCustomizer: { (request: inout URLRequest) in
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
          }
        )
      } else {
        authMethod = .endpoint(authEndpoint: endpoint)
      }
    } else if args["authorizer"] is Bool {
      // Dart tarafında onAuthorizer callback’i var
      authMethod = .authorizer(authorizer: self)
    }

    // --- Host/cluster seçimi ---
    var host: PusherHost = .defaultHost
    if let h = args["host"] as? String, !h.isEmpty {
      host = .host(h)                       // self-hosted: soketi.domain.com
    } else if let cl = args["cluster"] as? String {
      host = .cluster(cl)                   // pusher cluster
    }

    // --- TLS/port seçimi ---
    // ‘encrypted’ verilmişse useTLS’i override edelim; yoksa ‘useTLS’ bakılır.
    var useTLS: Bool = true
    if let enc = args["encrypted"] as? Bool {
      useTLS = enc
    } else if let tls = args["useTLS"] as? Bool {
      useTLS = tls
    }

    var port: Int = useTLS ? 443 : 80
    if useTLS, let wssPort = args["wssPort"] as? Int {
      port = wssPort                         // ör: 443
    } else if !useTLS, let wsPort = args["wsPort"] as? Int {
      port = wsPort                          // ör: 6001
    }

    // --- Opsiyonel timeouts ve path ---
    var activityTimeout: TimeInterval?
    if let at = args["activityTimeout"] as? TimeInterval {
      activityTimeout = at / 1000.0          // ms → s
    }
    var path: String?
    if let p = args["path"] as? String {
      path = p
    }

    // --- Pusher client options ---
    let options = PusherClientOptions(
      authMethod: authMethod,
      host: host,
      port: port,
      path: path,
      useTLS: useTLS,
      activityTimeout: activityTimeout
    )

    // --- Pusher instance ---
    pusher = Pusher(key: args["apiKey"] as! String, options: options)

    // Reconnect/timeout ayarları
    if let maxAttempts = args["maxReconnectionAttempts"] as? Int {
      pusher.connection.reconnectAttemptsMax = maxAttempts
    }
    if let maxGap = args["maxReconnectGapInSeconds"] as? TimeInterval {
      pusher.connection.maxReconnectGapInSeconds = maxGap
    }
    if let pongMs = args["pongTimeout"] as? TimeInterval {
      pusher.connection.pongResponseTimeoutInterval = pongMs / 1000.0
    }

    pusher.connection.delegate = self
    pusher.bind(eventCallback: onEvent)
    result(nil)
  }

  // MARK: - Authorizer (Dart tarafındaki onAuthorizer için)
  public func fetchAuthValue(socketID: String, channelName: String, completionHandler: @escaping (PusherAuth?) -> Void) {
    methodChannel!.invokeMethod("onAuthorizer", arguments: [
      "socketId": socketID,
      "channelName": channelName,
    ]) { authData in
      if let authData = authData as? [String: String] {
        completionHandler(
          PusherAuth(
            auth: authData["auth"]!,
            channelData: authData["channel_data"],
            sharedSecret: authData["shared_secret"]
          )
        )
      } else {
        completionHandler(nil)
      }
    }
  }

  // MARK: - Delegate
  public func changedConnectionState(from old: ConnectionState, to new: ConnectionState) {
    methodChannel.invokeMethod("onConnectionStateChange", arguments: [
      "previousState": old.stringValue(),
      "currentState": new.stringValue(),
    ])
  }

  public func debugLog(message _: String) {
    // print("DEBUG:", message)
  }

  public func subscribedToChannel(name _: String) {
    // Handled by global handler
  }

  public func failedToSubscribeToChannel(name _: String, response _: URLResponse?, data _: String?, error: NSError?) {
    methodChannel.invokeMethod(
      "onSubscriptionError", arguments: [
        "message": (error != nil) ? error!.localizedDescription : "",
        "error": error.debugDescription,
      ]
    )
  }

  public func receivedError(error: PusherError) {
    methodChannel.invokeMethod(
      "onError", arguments: [
        "message": error.message,
        "code": error.code ?? -1,
        "error": error.debugDescription,
      ]
    )
  }

  public func failedToDecryptEvent(eventName: String, channelName _: String, data: String?) {
    methodChannel.invokeMethod(
      "onDecryptionFailure", arguments: [
        "eventName": eventName,
        "reason": data,
      ]
    )
  }

  // MARK: - Connection
  func connect(result: @escaping FlutterResult) {
    pusher.connect()
    result(nil)
  }

  func disconnect(result: @escaping FlutterResult) {
    pusher.disconnect()
    result(nil)
  }

  func getSocketId(result: @escaping FlutterResult) {
    result(pusher.connection.socketId)
  }

  // MARK: - Subscription & Events
  func onEvent(event: PusherEvent) {
    var userId: String?
    if event.eventName == "pusher:subscription_succeeded" {
      if let channel = pusher.connection.channels.findPresence(name: event.channelName!) {
        userId = channel.myId
      }
    }
    methodChannel.invokeMethod(
      "onEvent", arguments: [
        "channelName": event.channelName,
        "eventName": event.eventName,
        "userId": event.userId ?? userId,
        "data": event.data,
      ]
    )
  }

  func subscribe(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as! [String: String]
    let channelName: String = args["channelName"]!
    if channelName.hasPrefix("presence-") {
      let onMemberAdded: (PusherPresenceChannelMember) -> Void = { user in
        self.methodChannel.invokeMethod("onMemberAdded", arguments: [
          "channelName": channelName,
          "user": ["userId": user.userId, "userInfo": user.userInfo],
        ])
      }
      let onMemberRemoved: (PusherPresenceChannelMember) -> Void = { user in
        self.methodChannel.invokeMethod("onMemberRemoved", arguments: [
          "channelName": channelName,
          "user": ["userId": user.userId, "userInfo": user.userInfo],
        ])
      }
      pusher.subscribeToPresenceChannel(
        channelName: channelName,
        onMemberAdded: onMemberAdded,
        onMemberRemoved: onMemberRemoved
      )
    } else {
      let onSubscriptionCount: (Int) -> Void = { subscriptionCount in
        self.methodChannel.invokeMethod(
          "onEvent", arguments: [
            "channelName": channelName,
            "eventName": "pusher:subscription_count",
            "userId": nil,
            "data": [
              "subscription_count": subscriptionCount,
            ],
          ]
        )
      }
      pusher.subscribe(channelName: channelName,
                       onSubscriptionCountChanged: onSubscriptionCount)
    }
    result(nil)
  }

  func unsubscribe(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as! [String: String]
    let channelName: String = args["channelName"]!
    pusher.unsubscribe(channelName)
    result(nil)
  }

  func trigger(call: FlutterMethodCall, result _: @escaping FlutterResult) {
    let args = call.arguments as! [String: String]
    let channelName: String = args["channelName"]!
    let eventName: String = args["eventName"]!
    let data: String? = args["data"]
    if let channel = pusher.connection.channels.find(name: channelName) {
      channel.trigger(eventName: eventName, data: data as Any)
    }
  }
}
