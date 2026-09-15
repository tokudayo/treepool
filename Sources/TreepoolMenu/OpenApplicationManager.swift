#if os(macOS)
import AppKit
import SwiftUI

struct OpenApplicationManager: View {
    @ObservedObject var store: MenuStore
    @Binding var isPresented: Bool
    @State private var selection: Set<OpenApplication.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            List(store.openApplications, selection: $selection) { application in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(application.name)
                }
                .tag(application.id)
            }
            .frame(width: 360, height: 200)

            Divider()

            HStack {
                Button {
                    if store.configureOpenApplications() { isPresented = false }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .help("Add applications")

                Button {
                    store.removeOpenApplications(identifiedBy: selection)
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .disabled(selection.isEmpty)
                .help("Remove selected applications")

                Spacer()
                Button("Done") { isPresented = false }
            }
            .padding(12)
        }
        .frame(width: 360)
    }
}
#endif
