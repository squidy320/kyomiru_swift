//
//  JSControllerDetails.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

struct LunaDetailsItem: Identifiable {
    let id = UUID()
    let description: String
    let aliases: String
    let airdate: String
}

struct EpisodeLink: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let href: String
    let duration: Int?
}

extension JSController {
    func fetchDetailsJS(url: String, completion: @escaping ([LunaDetailsItem], [EpisodeLink]) -> Void) {
        guard let url = URL(string: url) else {
            LunaLogger.shared.log("Invalid URL in fetchDetailsJS: \(url)", type: "Error")
            completion([], [])
            return
        }
        
        if let exception = context.exception {
            LunaLogger.shared.log("JavaScript exception: \(exception.debugSummary)", type: "Error")
            completion([], [])
            return
        }
        
        guard let extractDetailsFunction = context.objectForKeyedSubscript("extractDetails"),
              let extractEpisodesFunction = context.objectForKeyedSubscript("extractEpisodes") else {
            LunaLogger.shared.log("Missing JS functions in module", type: "Error")
            completion([], [])
            return
        }
        
        var resultItems: [LunaDetailsItem] = []
        var episodeLinks: [EpisodeLink] = []
        let dispatchGroup = DispatchGroup()
        let lock = NSLock()
        
        // 1. Details
        dispatchGroup.enter()
        let promiseDetails = extractDetailsFunction.call(withArguments: [url.absoluteString])
        
        let detailsThen: @convention(block) (JSValue) -> Void = { result in
            if let json = result.toString(), let data = json.data(using: .utf8) {
                if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    lock.lock()
                    resultItems = array.map { item in
                        LunaDetailsItem(
                            description: item["description"] as? String ?? "",
                            aliases: item["aliases"] as? String ?? "",
                            airdate: item["airdate"] as? String ?? ""
                        )
                    }
                    lock.unlock()
                }
            }
            dispatchGroup.leave()
        }
        
        let detailsCatch: @convention(block) (JSValue) -> Void = { _ in dispatchGroup.leave() }
        
        if let promise = promiseDetails, !promise.isUndefined {
            promise.invokeMethod("then", withArguments: [JSValue(object: detailsThen, in: context) as Any])
            promise.invokeMethod("catch", withArguments: [JSValue(object: detailsCatch, in: context) as Any])
        } else {
            dispatchGroup.leave()
        }
        
        // 2. Episodes
        dispatchGroup.enter()
        let promiseEpisodes = extractEpisodesFunction.call(withArguments: [url.absoluteString])
        
        let episodesThen: @convention(block) (JSValue) -> Void = { result in
            if let json = result.toString(), let data = json.data(using: .utf8) {
                if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    lock.lock()
                    episodeLinks = array.map { item in
                        EpisodeLink(
                            number: item["number"] as? Int ?? 0,
                            title: "",
                            href: item["href"] as? String ?? "",
                            duration: nil
                        )
                    }
                    lock.unlock()
                }
            }
            dispatchGroup.leave()
        }
        
        let episodesCatch: @convention(block) (JSValue) -> Void = { _ in dispatchGroup.leave() }
        
        if let promise = promiseEpisodes, !promise.isUndefined {
            promise.invokeMethod("then", withArguments: [JSValue(object: episodesThen, in: context) as Any])
            promise.invokeMethod("catch", withArguments: [JSValue(object: episodesCatch, in: context) as Any])
        } else {
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) {
            completion(resultItems, episodeLinks)
        }
    }
    
    func fetchEpisodesJS(url: String, completion: @escaping ([EpisodeLink]) -> Void) {
        guard let url = URL(string: url) else {
            completion([])
            return
        }
        
        if let exception = context.exception {
            LunaLogger.shared.log("JavaScript exception: \(exception.debugSummary)", type: "Error")
            completion([])
            return
        }
        
        guard let extractEpisodesFunction = context.objectForKeyedSubscript("extractEpisodes") else {
            completion([])
            return
        }
        
        let promiseValue = extractEpisodesFunction.call(withArguments: [url.absoluteString])
        guard let promise = promiseValue, !promise.isUndefined && !promise.isNull else {
            completion([])
            return
        }

        var hasCompleted = false
        let lock = NSLock()
        
        let timeoutWorkItem = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            guard !hasCompleted else { return }
            hasCompleted = true
            DispatchQueue.main.async { completion([]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutWorkItem)
        
        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else { lock.unlock(); return }
            hasCompleted = true
            lock.unlock()
            
            var links: [EpisodeLink] = []
            if let json = result.toString(), let data = json.data(using: .utf8) {
                if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    links = array.map { item in
                        EpisodeLink(
                            number: item["number"] as? Int ?? 0,
                            title: "",
                            href: item["href"] as? String ?? "",
                            duration: nil
                        )
                    }
                }
            }
            DispatchQueue.main.async { completion(links) }
        }
        
        let catchBlock: @convention(block) (JSValue) -> Void = { _ in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else { lock.unlock(); return }
            hasCompleted = true
            lock.unlock()
            DispatchQueue.main.async { completion([]) }
        }
        
        promise.invokeMethod("then", withArguments: [JSValue(object: thenBlock, in: context) as Any])
        promise.invokeMethod("catch", withArguments: [JSValue(object: catchBlock, in: context) as Any])
    }
}
