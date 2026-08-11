import Foundation

private struct FlexibleInt64: Decodable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
            return
        }
        if let text = try? container.decode(String.self), let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = value
            return
        }
        throw SimpleFINProtocolError.invalidResponse("expected integer epoch")
    }
}

private struct FlexibleDecimalString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(Decimal.self) {
            self.value = NSDecimalNumber(decimal: value).stringValue
            return
        }
        throw SimpleFINProtocolError.invalidResponse("expected decimal amount")
    }
}

private struct FlexibleStringArray: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([String].self) {
            self.values = values
        } else if let value = try? container.decode(String.self) {
            self.values = [value]
        } else {
            self.values = []
        }
    }
}

extension SimpleFINRemoteOrganization {
    private enum CodingKeys: String, CodingKey { case id, domain, name }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            self.init(name: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            domain: try container.decodeIfPresent(String.self, forKey: .domain),
            name: try container.decodeIfPresent(String.self, forKey: .name)
        )
    }
}

extension SimpleFINRemoteTransaction {
    private enum CodingKeys: String, CodingKey {
        case id, amount, posted, transactedAt = "transacted_at", description, payee, pending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let posted = try container.decode(FlexibleInt64.self, forKey: .posted).value
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            amount: try container.decode(FlexibleDecimalString.self, forKey: .amount).value,
            postedEpoch: posted,
            transactedAtEpoch: try container.decodeIfPresent(FlexibleInt64.self, forKey: .transactedAt)?.value,
            description: try container.decodeIfPresent(String.self, forKey: .description),
            payee: try container.decodeIfPresent(String.self, forKey: .payee),
            pending: try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        )
    }
}

extension SimpleFINRemoteAccount {
    private enum CodingKeys: String, CodingKey {
        case id, name, currency, balance
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
        case org, connectionID = "conn_id"
        case transactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            currency: try container.decode(String.self, forKey: .currency),
            balance: try container.decode(FlexibleDecimalString.self, forKey: .balance).value,
            availableBalance: try container.decodeIfPresent(FlexibleDecimalString.self, forKey: .availableBalance)?.value,
            balanceDateEpoch: try container.decodeIfPresent(FlexibleInt64.self, forKey: .balanceDate)?.value,
            organization: try container.decodeIfPresent(SimpleFINRemoteOrganization.self, forKey: .org),
            connectionID: try container.decodeIfPresent(String.self, forKey: .connectionID),
            transactions: try container.decodeIfPresent([SimpleFINRemoteTransaction].self, forKey: .transactions) ?? []
        )
    }
}

extension SimpleFINAccountsResponse {
    private enum CodingKeys: String, CodingKey {
        case accounts, errors, errlist, balanceDate = "balance-date"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let errors = (try container.decodeIfPresent(FlexibleStringArray.self, forKey: .errors)?.values ?? [])
            + (try container.decodeIfPresent(FlexibleStringArray.self, forKey: .errlist)?.values ?? [])
        try self.init(
            accounts: try container.decodeIfPresent([SimpleFINRemoteAccount].self, forKey: .accounts) ?? [],
            errors: errors,
            balanceDateEpoch: try container.decodeIfPresent(FlexibleInt64.self, forKey: .balanceDate)?.value
        )
    }
}
