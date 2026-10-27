import Foundation

struct NetworkIdentity: Sendable {
    let ipAddress: String
    let countryCode: String

    nonisolated var countryFlag: String {
        let regionalIndicatorOffset: UInt32 = 127_397
        let scalars = countryCode
            .uppercased()
            .unicodeScalars
            .compactMap { UnicodeScalar($0.value + regionalIndicatorOffset) }

        guard scalars.count == 2 else {
            return "🌐"
        }

        return String(String.UnicodeScalarView(scalars))
    }
}

enum NetworkIdentityService {
    private struct IPResponse: Decodable {
        let ip: String
    }

    private struct CountryResponse: Decodable {
        let country: String
    }

    static func fetch() async -> NetworkIdentity? {
        do {
            let ipResponse: IPResponse = try await request(
                URL(string: "https://api.ipify.org?format=json")
            )
            guard Self.isIPv4Address(ipResponse.ip) else {
                return nil
            }

            let countryResponse: CountryResponse = try await request(
                URL(string: "https://api.country.is/\(ipResponse.ip)")
            )
            guard countryResponse.country.count == 2 else {
                return nil
            }

            return NetworkIdentity(
                ipAddress: ipResponse.ip,
                countryCode: countryResponse.country.uppercased()
            )
        } catch {
            return nil
        }
    }

    private static func request<Value: Decodable>(_ url: URL?) async throws -> Value {
        guard let url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.allSatisfy { component in
            guard let number = UInt8(component) else {
                return false
            }
            return String(number) == component
        }
    }
}
