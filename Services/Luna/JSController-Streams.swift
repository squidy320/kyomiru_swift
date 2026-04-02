//
//  JSLoader-Streams.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

extension JSController {
    func fetchStreamUrlJS(episodeUrl: String, softsub: Bool = false, module: Service, completion: @escaping ((streams: [String]?, subtitles: [String]?,sources: [[String:Any]]? )) -> Void) {
        if let exception = context.exception {
            LunaLogger.shared.log("JavaScript exception: \(exception.debugSummary)", type: "Error")
            completion((nil, nil, nil))
            return
        }
        
        guard let extractStreamUrlFunction = context.objectForKeyedSubscript("extractStreamUrl") else {
            LunaLogger.shared.log("No JavaScript function extractStreamUrl found", type: "Error")
            completion((nil, nil, nil))
            return
        }
        
        let promiseValue = extractStreamUrlFunction.call(withArguments: [episodeUrl])
        guard let promise = promiseValue, !promise.isUndefined && !promise.isNull else {
            LunaLogger.shared.log("extractStreamUrl did not return a valid Promise", type: "Error")
            completion((nil, nil, nil))
            return
        }

        var hasCompleted = false
        let lock = NSLock()
        
        let timeoutWorkItem = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            guard !hasCompleted else { return }
            hasCompleted = true
            LunaLogger.shared.log("Timeout for extractStreamUrl", type: "Warning")
            DispatchQueue.main.async { completion((nil, nil, nil)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeoutWorkItem)
        
        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else { lock.unlock(); return }
            hasCompleted = true
            lock.unlock()
            
            if result.isNull || result.isUndefined {
                DispatchQueue.main.async { completion((nil, nil, nil)) }
                return
            }
            
            guard let jsonString = result.toString(),
                  let data = jsonString.data(using: .utf8) else {
                DispatchQueue.main.async { completion((nil, nil, nil)) }
                return
            }
            
            var res: (streams: [String]?, subtitles: [String]?, sources: [[String:Any]]?) = (nil, nil, nil)
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let streamSources = json["streams"] as? [[String:Any]] {
                        res.sources = streamSources
                    } else if let streamsArray = json["streams"] as? [String] {
                        res.streams = streamsArray
                    } else if let streamUrl = json["stream"] as? String {
                        res.streams = [streamUrl]
                    }
                    
                    if let subsArray = json["subtitles"] as? [String] {
                        res.subtitles = subsArray
                    } else if let subtitleUrl = json["subtitles"] as? String {
                        res.subtitles = [subtitleUrl]
                    }
                } else if let streamsArray = try JSONSerialization.jsonObject(with: data) as? [String] {
                    res.streams = streamsArray
                }
            } catch {
                res.streams = [jsonString]
            }
            
            DispatchQueue.main.async { completion(res) }
        }
        
        let catchBlock: @convention(block) (JSValue) -> Void = { error in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else { lock.unlock(); return }
            hasCompleted = true
            lock.unlock()
            
            LunaLogger.shared.log("extractStreamUrl Promise rejected: \(error.toString() ?? "unknown")", type: "Error")
            DispatchQueue.main.async { completion((nil, nil, nil)) }
        }
        
        promise.invokeMethod("then", withArguments: [JSValue(object: thenBlock, in: context) as Any])
        promise.invokeMethod("catch", withArguments: [JSValue(object: catchBlock, in: context) as Any])
    }
}
