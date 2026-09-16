import LedgerCore
import SwiftUI

/// §2.2 first launch: currency, IANA time zone, and the immutable first budget
/// month (current month or earlier; future months rejected).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var name = "My Budget"
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var firstMonthOffset = 0 // months before the current month

    private var timeZones: [String] { TimeZone.knownTimeZoneIdentifiers }

    private var currentMonthInZone: BudgetMonth? {
        guard let calendar = try? BudgetCalendar(timeZoneIdentifier: timeZoneID) else { return nil }
        return calendar.budgetDate(fromEpoch: Int64(Date().timeIntervalSince1970.rounded()))?.budgetMonth
    }

    private var firstMonthChoices: [(offset: Int, month: BudgetMonth)] {
        guard var month = currentMonthInZone else { return [] }
        var result: [(Int, BudgetMonth)] = []
        for offset in 0...12 {
            result.append((offset, month))
            month = month.previous
        }
        return result
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Create your first budget")
                .font(.title2.bold())
            Text("All data stays on this Mac in a local SQLite file. The currency, time zone, and first month are fixed once the budget is created.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Form {
                TextField("Budget name", text: $name)
                TextField("Currency (ISO 4217)", text: $currency)
                    .accessibilityIdentifier("ledgerbar.onboarding.currency")
                    .onChange(of: currency) { _, value in
                        currency = String(value.uppercased().prefix(3))
                    }
                Picker("Time zone", selection: $timeZoneID) {
                    ForEach(timeZones, id: \.self) { zone in
                        Text(zone).tag(zone)
                    }
                }
                .accessibilityIdentifier("ledgerbar.onboarding.time-zone")
                Picker("First budget month", selection: $firstMonthOffset) {
                    ForEach(firstMonthChoices, id: \.offset) { choice in
                        Text(MoneyFormatting.monthTitle(choice.month)).tag(choice.offset)
                    }
                }
                .accessibilityIdentifier("ledgerbar.onboarding.first-month")
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460)

            Button("Create Budget") {
                guard currency.count == 3,
                      let choice = firstMonthChoices.first(where: { $0.offset == firstMonthOffset })
                else { return }
                let selectedCurrency = currency
                let selectedZone = timeZoneID
                let month = choice.month
                let budgetName = name
                Task {
                    await model.createBudget(
                        name: budgetName,
                        currency: selectedCurrency,
                        timeZoneIdentifier: selectedZone,
                        firstMonth: month
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(currency.count != 3 || firstMonthChoices.isEmpty)
            .accessibilityIdentifier("ledgerbar.onboarding.create-budget")
        }
        .padding(30)
    }
}
