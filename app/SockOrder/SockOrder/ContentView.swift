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

    // bump ?v= if you update the JSON and need to bust cache
    private let catalogURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/catalog.json?v=3")!
    private let availabilityURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/availability.json?v=3")!

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
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func isAvailable(styleID: String, size: String) -> Bool {
        availability[styleID]?[size] ?? false
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var svc = CatalogService()

    @State private var selectedPark: Park? // user selection (may be nil)
    @State private var note: String = ""
    @State private var selectedQuantities: [String: [String: Int]] = [:]

    @State private var submitting = false
    @State private var submitAlert: (title: String, message: String)? = nil

    // Your Google Apps Script webhook URL
    private let ORDER_WEBHOOK_URL = URL(string: "https://script.google.com/macros/s/AKfycbwztVhKL5etGDowbQAKkR2cIRyxGUD0e0v_qPUMh5TQgM86MJVMxBFexlQ89I21HqMM/exec")!

    // Resolves to user's selection OR the first park when available
    private var resolvedPark: Park? {
        selectedPark ?? svc.catalog?.parks.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Custom header
                    Text("AMG Sock Orders")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)

                    Group {
                        if svc.loading {
                            ProgressView("Loading catalog…")
                        } else if let cat = svc.catalog {
                            parkPicker(cat)

                            VStack(spacing: 16) {
                                ForEach(cat.styles) { style in
                                    styleCard(style)
                                }
                            }

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
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
            .onAppear {
                if svc.catalog == nil { svc.load() }
            }
        }
    }

    // MARK: - Subviews

    private func parkPicker(_ cat: Catalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select Park")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Select Park", selection: Binding(
                get: { resolvedPark },   // shows first park by default
                set: { selectedPark = $0 }
            )) {
                ForEach(cat.parks) { park in
                    Text(cityOnly(park.name)).tag(Optional(park))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }

    private func styleCard(_ style: SockStyle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: style.image)) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(width: 72, height: 72)
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(width: 72, height: 72).clipped().cornerRadius(8)
                    case .failure(_):
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                            Image(systemName: "photo")
                        }.frame(width: 72, height: 72)
                    @unknown default:
                        EmptyView()
                    }
                }

                VStack(alignment: .leading) {
                    Text(style.name).font(.title3).fontWeight(.bold)
                    Text("Select sizes & quantities")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }

            let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(style.sizes, id: \.self) { size in
                    let available = svc.isAvailable(styleID: style.id, size: size)

                    SizePill(
                        label: size,
                        quantity: selectedQuantities[style.id]?[size] ?? 0,
                        available: available,
                        onMinus: {
                            guard available else { return }
                            let current = selectedQuantities[style.id]?[size] ?? 0
                            setQty(styleID: style.id, size: size, max(0, current - 1))
                        },
                        onPlus: {
                            guard available else { return }
                            let current = selectedQuantities[style.id]?[size] ?? 0
                            setQty(styleID: style.id, size: size, current + 1)
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemBackground)))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes (optional)")
                .font(.subheadline).foregroundColor(.secondary)
            TextField("Add any special instructions…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var submitButton: some View {
        Button { submitOrder() } label: {
            if submitting {
                ProgressView().padding(.vertical, 6)
            } else {
                Text("Submit Order").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit || submitting)
        .padding(.bottom, 8)
        .alert(item: Binding(
            get: { submitAlert.map { AlertItem(title: $0.title, message: $0.message) } },
            set: { _ in submitAlert = nil }
        )) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Helpers

    private func setQty(styleID: String, size: String, _ qty: Int) {
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
        // must have a park (resolved) and at least one available line with qty > 0
        guard resolvedPark != nil else { return false }
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
                lines.append(["styleID": styleID, "size": size, "cases": qty])
            }
        }
        return [
            "park": resolvedPark?.name ?? "",
            "note": note,
            "lines": lines,
            "timestamp": ISO8601DateFormatter().string(from: .now)
        ]
    }

    private func submitOrder() {
        let order = buildOrderPayload()
        guard (order["lines"] as? [[String: Any]])?.isEmpty == false else {
            submitAlert = ("Nothing to submit", "Please add at least one size/case.")
            return
        }
        submitting = true
        Task {
            do {
                var req = URLRequest(url: ORDER_WEBHOOK_URL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.httpBody = try JSONSerialization.data(withJSONObject: order)

                let (_, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                // Success
                submitting = false
                selectedQuantities.removeAll()
                note = ""
                submitAlert = ("Order Submitted", "We received your order and emailed a copy.")
            } catch {
                submitting = false
                submitAlert = ("Submit failed", "Please try again later.")
            }
        }
    }
}

private struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Size Pill (with Unavailable cue)

private struct SizePill: View {
    let label: String
    let quantity: Int
    let available: Bool
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).bold()

            Button(action: onMinus) {
                Image(systemName: "minus.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!available || quantity == 0)

            Text("\(quantity)")
                .font(.subheadline).monospacedDigit()
                .frame(minWidth: 18)

            Button(action: onPlus) {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!available)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(available ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.15))
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
    }
}
