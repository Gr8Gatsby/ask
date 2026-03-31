import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2") }
            FeedView()
                .tabItem { Label("Feed", systemImage: "list.bullet.rectangle") }
        }
    }
}
