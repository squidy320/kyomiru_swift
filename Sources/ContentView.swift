import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Kyomiru")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
        }
    }
}
