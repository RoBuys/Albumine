import SwiftUI

/// Date correction for a selection: shift (wrong camera clock) or exact date (scanned photos).
/// Files are not modified (the date is written to the XMP when that option is on).
struct DateFixSheet: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    enum Mode: String, CaseIterable, Identifiable {
        case shift = "Décaler"
        case set = "Date précise"
        var id: String { rawValue }
    }

    @Etat private var mode: Mode = .shift
    @Etat private var years = 0
    @Etat private var months = 0
    @Etat private var days = 0
    @Etat private var hours = 0
    @Etat private var minutes = 0
    @Etat private var target = Date()
    @Etat private var keepSpacing = true

    private var sorted: [Photo] { photos.sorted { $0.date < $1.date } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Corriger la date de \(photos.count) élément\(photos.count > 1 ? "s" : "")").font(.title3.weight(.semibold))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                if mode == .shift {
                    stepper("Années", $years, -50...50)
                    stepper("Mois", $months, -11...11)
                    stepper("Jours", $days, -365...365)
                    stepper("Heures", $hours, -23...23)
                    stepper("Minutes", $minutes, -59...59)
                    Text("Exemple : un appareil resté à l'heure d'hiver → +1 heure ; une date réglée un an trop tôt → +1 année.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    DatePicker("Nouvelle date", selection: $target)
                    Toggle("Conserver l'écart entre les photos", isOn: $keepSpacing)
                    Text(keepSpacing
                         ? "La plus ancienne prend cette date ; les autres gardent leur écart avec elle."
                         : "Toutes les photos prennent exactement cette date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aperçu").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(sorted.prefix(4)), id: \.id) { p in
                    HStack {
                        Text(p.name).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                        Text(p.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(newDate(for: p).formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                    }
                    .font(.caption)
                }
                if photos.count > 4 { Text("…").font(.caption).foregroundStyle(.secondary) }
            }

            HStack {
                if photos.contains(where: { library.hasDateOverride($0) }) {
                    Button("Rétablir les dates d'origine") {
                        library.resetDates(photos)
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Appliquer") { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .shift && shift == DateComponents(year: 0, month: 0, day: 0, hour: 0, minute: 0))
            }
            Text("Les fichiers ne sont pas modifiés : la date corrigée est utilisée pour le tri, les souvenirs, les événements (et écrite dans le XMP si l'option est activée).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { target = sorted.first?.date ?? Date() }
    }

    private var shift: DateComponents {
        DateComponents(year: years, month: months, day: days, hour: hours, minute: minutes)
    }

    private func newDate(for p: Photo) -> Date {
        switch mode {
        case .shift:
            return Calendar.current.date(byAdding: shift, to: p.date) ?? p.date
        case .set:
            guard keepSpacing, let first = sorted.first else { return target }
            return target.addingTimeInterval(p.date.timeIntervalSince(first.date))
        }
    }

    private func apply() {
        switch mode {
        case .shift: library.shiftDates(photos, by: shift)
        case .set: library.setDates(photos, to: target, keepSpacing: keepSpacing)
        }
    }

    private func stepper(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text(value.wrappedValue > 0 ? "+\(value.wrappedValue)" : "\(value.wrappedValue)")
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
            }
        }
    }
}
