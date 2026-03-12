//
//  JSController.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import JavaScriptCore

class JSController: NSObject, ObservableObject {
    static let shared = JSController()
    var context: JSContext
    
    override init() {
        self.context = JSContext()
        super.init()
        setupContext()
    }
    
    func setupContext() {
        context.setupJavaScriptEnvironment()
    }
    
    func loadScript(_ script: String) {
        context = JSContext()
        context.setupJavaScriptEnvironment()
        let sourceURL = URL(string: "luna://animepahe.js")
        if let sourceURL {
            context.evaluateScript(script, withSourceURL: sourceURL)
        } else {
            context.evaluateScript(script)
        }
        if let exception = context.exception {
            var detail = exception.debugSummary
            let line = exception.objectForKeyedSubscript("line")?.toInt32() ?? 0
            if line > 0 {
                let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
                let idx = Int(line - 1)
                if idx >= 0 && idx < lines.count {
                    let snippet = String(lines[idx]).prefix(200)
                    detail += "\nLine \(line): \(snippet)"
                }
            }
            LunaLogger.shared.log("Error loading script: \(detail)", type: "Error")
        }
    }
}
