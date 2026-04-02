//
//  JSController-Search.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

struct SearchItem: Identifiable {
    let id = UUID()
    let title: String
    let imageUrl: String
    let href: String
}

extension JSController {
    func fetchJsSearchResults(keyword: String, module: Service, completion: @escaping ([SearchItem]) -> Void) {
        if let exception = context.exception {
            LunaLogger.shared.log("JavaScript exception: \(exception.debugSummary)", type: "Error")
            completion([])
            return
        }
        
        guard let searchResultsFunction = context.objectForKeyedSubscript("searchResults") else {
            LunaLogger.shared.log("Search function not found in module", type: "Error")
            completion([])
            return
        }
        
        let promiseValue = searchResultsFunction.call(withArguments: [keyword])
        guard let promise = promiseValue, !promise.isUndefined && !promise.isNull else {
            LunaLogger.shared.log("Search function returned invalid response", type: "Error")
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
            LunaLogger.shared.log("Timeout for searchResults", type: "Warning")
            DispatchQueue.main.async {
                completion([])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeoutWorkItem)
        
        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else {
                lock.unlock()
                return
            }
            hasCompleted = true
            lock.unlock()

            if let jsonString = result.toString(),
               let data = jsonString.data(using: .utf8) {
                do {
                    if let array = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                        let resultItems = array.compactMap { item -> SearchItem? in
                            guard let title = item["title"] as? String,
                                  let href = item["href"] as? String else {
                                return nil
                            }
                            let imageUrl = (item["image"] as? String) ?? (item["imageUrl"] as? String) ?? ""
                            return SearchItem(title: title, imageUrl: imageUrl, href: href)
                        }
                        DispatchQueue.main.async { completion(resultItems) }
                    } else {
                        DispatchQueue.main.async { completion([]) }
                    }
                } catch {
                    DispatchQueue.main.async { completion([]) }
                }
            } else {
                DispatchQueue.main.async { completion([]) }
            }
        }
        
        let catchBlock: @convention(block) (JSValue) -> Void = { error in
            timeoutWorkItem.cancel()
            lock.lock()
            guard !hasCompleted else {
                lock.unlock()
                return
            }
            hasCompleted = true
            lock.unlock()
            
            LunaLogger.shared.log("Search operation failed: \(error.toString() ?? "unknown")", type: "Error")
            DispatchQueue.main.async {
                completion([])
            }
        }
        
        let thenFunction = JSValue(object: thenBlock, in: context)
        let catchFunction = JSValue(object: catchBlock, in: context)
        
        promise.invokeMethod("then", withArguments: [thenFunction as Any])
        promise.invokeMethod("catch", withArguments: [catchFunction as Any])
    }
}
