import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var showAddDevice = false

    var body: some View {
        DeviceGalleryView {
            showAddDevice = true
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView(defaultAccount: accounts.first { $0.isLive })
        }
    }
}
