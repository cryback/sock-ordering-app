import SwiftUI

// MARK: - Models

struct Catalog: Codable {
    var parks: [Park]
    var styles: [SockStyle]
}

struct Park: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct SockStyle: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let sizes: [String]
    let image: String
}

struct AvailabilityPayload: Codable {
    let styles: [String: [String: Bool]]
}

// MARK: - Data Service

@MainActor
final class CatalogService: ObservableObject {
    @Published var catalog: Catalog?
    @Published var availability: [String: [String: Bool]] = [:]
    @Published var loading = true
    @Published var error: String?

    // Update these URLs if your repo/branch changes
    private let catalogURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/catalog.json")!
    private let availabilityURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/availability.json")!

    func load() {
        Task {
            do {
                async let cat: Catalog = fetch(catalogURL)
                async let avail: AvailabilityPayload = fetch(availabilityURL)
                let (catalog, availabilityPayload) = try await (cat, avail)
                self.catalog = catalog
                self.availability = availabilityPayload.styles
                self.loading = false
                self.error = nil
            } catch {
                self.loading = false
                self.error = "Could not load data"
                print("Load error:", error)
            }
        }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData          // <- bust cache
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Availability lookup; DEFAULT = false (blocked) if not found
    func isAvailable(styleID: String, size: String) -> Bool {
        availability[styleID]?[size] ?? false
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var svc = CatalogService()

    @State private var selectedPark: Park?
    @State private var note: String = ""
    @State private var selectedQuantities: [String: [String: Int]] = [:] // styleID -> size -> qty

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Custom centered header with spacing above "Select Park"
                    VStack(spacing: 6) {
                        Text("AMG Sock Orders")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    Group {
                        if svc.loading {
                            ProgressView("Loading catalog…")
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if let cat = svc.catalog {
                            // Select Park
                            parkPicker(cat)
                                .padding(.top, 4)

                            // Styles
                            VStack(spacing: 16) {
                                ForEach(cat.styles) { style in
                                    styleCard(style)
                                }
                            }
                            .padding(.top, 4)

                            // Notes + Submit
                            noteField
                            submitButton
                        } else {
                            VStack(spacing: 12) {
                                Text("Could Not Load Data")
                                    .font(.headline)
                                    .foregroundColor(.red)
                                if let e = svc.error {
                                    Text(e).foregroundColor(.secondary)
                                }
                                Button("Retry") { svc.load() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color(UIColor.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { EmptyView() } } // hide default title
            .onAppear { if svc.catalog == nil { svc.load() } }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func parkPicker(_ cat: Catalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select Park")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Select Park", selection: Binding(
                get: { selectedPark ?? cat.parks.first },
                set: { selectedPark = $0 }
            )) {
                ForEach(cat.parks) { park in
                    Text(cityOnly(park.name)).tag(Optional(park))
                }
            }
            .pickerStyle(.menu)
            .tint(.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private func styleCard(_ style: SockStyle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                AsyncImage(url: URL(string: style.image)) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 72, height: 72)
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipped()
                            .cornerRadius(8)
                    case .failure(_):
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.15))
                            Image(systemName: "photo")
                                .imageScale(.large)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 72, height: 72)
                    @unknown default:
                        EmptyView()
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name).font(.title3).fontWeight(.bold)
                    Text("Select sizes & quantities")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Adaptive grid of neat, self-sized pills
            let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(style.sizes, id: \.self) { size in
                    let available = svc.isAvailable(styleID: style.id, size: size)

                    SizePill(
                        label: size,
                        quantity: selectedQuantities[style.id]?[size] ?? 0,
                        available: available,
                        onMinus: {
                            guard available else { return } // hard block
                            let current = selectedQuantities[style.id]?[size] ?? 0
                            setQty(styleID: style.id, size: size, max(0, current - 1))
                        },
                        onPlus: {
                            guard available else { return } // hard block
                            let current = selectedQuantities[style.id]?[size] ?? 0
                            setQty(styleID: style.id, size: size, current + 1)
                        }
                    )
                    .opacity(available ? 1.0 : 0.4)
                    .disabled(!available) // UI disable
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes (optional)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("Add any special instructions…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        Button {
            let order = buildOrderPayload()
            print("ORDER:", order) // TODO: hook up webhook
        } label: {
            Text("Submit Order")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private func setQty(styleID: String, size: String, _ qty: Int) {
        // Do not allow changes for unavailable sizes
        guard svc.isAvailable(styleID: styleID, size: size) else { return }

        var styleMap = selectedQuantities[styleID] ?? [:]
        if qty == 0 {
            styleMap.removeValue(forKey: size)
        } else {
            styleMap[size] = qty
        }
        selectedQuantities[styleID] = styleMap.isEmpty ? nil : styleMap
    }

    private var canSubmit: Bool {
        guard selectedPark != nil else { return false }
        // Must have at least one nonzero qty AND all lines must be available
        return selectedQuantities.contains { styleID, sizes in
            sizes.contains { size, qty in qty > 0 && svc.isAvailable(styleID: styleID, size: size) }
        }
    }

    private func cityOnly(_ fullName: String) -> String {
        if let comma = fullName.firstIndex(of: ",") {
            return String(fullName[..<comma])
        }
        return fullName
    }

    private func buildOrderPayload() -> [String: Any] {
        var lines: [[String: Any]] = []
        for (styleID, sizes) in selectedQuantities {
            for (size, qty) in sizes where qty > 0 && svc.isAvailable(styleID: styleID, size: size) {
                lines.append([
                    "styleID": styleID,
                    "size": size,
                    "cases": qty
                ])
            }
        }
        return [
            "park": selectedPark?.name ?? "",
            "note": note,
            "lines": lines,
            "timestamp": ISO8601DateFormatter().string(from: .now)
        ]
    }
}

// MARK: - Reusable Size Pill (with "Unavailable" cue)

private struct SizePill: View {
    let label: String
    let quantity: Int
    let available: Bool
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline).bold()

            Button(action: onMinus) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!available || quantity == 0)

            Text("\(quantity)")
                .font(.subheadline).monospacedDigit()
                .frame(minWidth: 18, alignment: .center)

            Button(action: onPlus) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!available)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(available
                           ? Color.accentColor.opacity(0.12)
                           : Color.gray.opacity(0.15))
        )
        .overlay(
            Capsule().strokeBorder(
                available ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.25),
                lineWidth: 1
            )
        )
        .overlay(alignment: .trailing) {
            if !available {
                Text("Unavailable")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 6)
            }
        }
        .opacity(available ? 1.0 : 0.4)
        .fixedSize(horizontal: true, vertical: false) // keeps pills compact
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.sizeCategory, .large)
    }
}
