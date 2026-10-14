import Foundation
import MapKit
import Testing
@testable import ArchTrip

/// Error-code classification of a failed Place ID lookup: only explicit no-connectivity
/// codes are "offline"; timeouts and TLS / DNS / connection failures are distinct kinds;
/// MapKit's throttling and not-found verdicts win; a wrapper's underlying cause is read.
struct PlaceFetchClassificationTests {
    private func url(_ code: URLError.Code) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue)
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func mapKit(_ code: MKError.Code, underlying: NSError? = nil) -> NSError {
        NSError(domain: MKErrorDomain, code: Int(code.rawValue), userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    @Test func onlyExplicitNoConnectivityCodesAreOffline() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive] {
            #expect(MapKitPlaceFetcher.classify(url(code)) == .offline, "\(code.rawValue)")
        }
        for code in [ENETDOWN, ENETUNREACH, EHOSTUNREACH, EHOSTDOWN] {
            #expect(MapKitPlaceFetcher.classify(posix(code)) == .offline, "POSIX \(code)")
        }
    }

    @Test func timeoutsAreNotOffline() {
        #expect(MapKitPlaceFetcher.classify(url(.timedOut)) == .timeout)
        #expect(MapKitPlaceFetcher.classify(posix(ETIMEDOUT)) == .timeout)
    }

    @Test func tlsDnsAndConnectionFailuresAreTransport() {
        for code: URLError.Code in [
            .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .badServerResponse, .cannotParseResponse, .unknown,
        ] {
            #expect(MapKitPlaceFetcher.classify(url(code)) == .transport, "\(code.rawValue)")
        }
        #expect(MapKitPlaceFetcher.classify(posix(ECONNREFUSED)) == .transport)
        #expect(MapKitPlaceFetcher.classify(posix(ECONNRESET)) == .transport)
    }

    @Test func mapKitVerdictsKeepTheirMeaning() {
        #expect(MapKitPlaceFetcher.classify(mapKit(.loadingThrottled)) == .throttled)
        #expect(MapKitPlaceFetcher.classify(mapKit(.placemarkNotFound)) == .notFound)
        #expect(MapKitPlaceFetcher.classify(mapKit(.serverFailure)) == .server)
        #expect(MapKitPlaceFetcher.classify(mapKit(.decodingFailed)) == .server)
        #expect(MapKitPlaceFetcher.classify(mapKit(.unknown)) == .server)
        #expect(MapKitPlaceFetcher.classify(mapKit(.directionsNotFound)) == .notFound, "travel search: no route is not a server failure")
    }

    /// MapKit often wraps the real cause: a generic MapKit error with a URL or POSIX error
    /// underneath is classified by that cause, through more than one level; a definitive
    /// MapKit verdict (throttled, not found) is not overridden by its cause.
    @Test func wrappedCausesAreRead() {
        #expect(MapKitPlaceFetcher.classify(mapKit(.unknown, underlying: url(.notConnectedToInternet))) == .offline)
        #expect(MapKitPlaceFetcher.classify(mapKit(.serverFailure, underlying: url(.timedOut))) == .timeout)
        #expect(MapKitPlaceFetcher.classify(mapKit(.serverFailure, underlying: url(.secureConnectionFailed))) == .transport)
        let twoLevels = mapKit(.unknown, underlying: NSError(domain: "GEOErrorDomain", code: -3, userInfo: [NSUnderlyingErrorKey: posix(ENETUNREACH)]))
        #expect(MapKitPlaceFetcher.classify(twoLevels) == .offline)
        #expect(MapKitPlaceFetcher.classify(mapKit(.loadingThrottled, underlying: url(.notConnectedToInternet))) == .throttled)
        #expect(MapKitPlaceFetcher.classify(mapKit(.placemarkNotFound, underlying: url(.timedOut))) == .notFound)
    }

    @Test func unknownDomainsAreServerFailures() {
        #expect(MapKitPlaceFetcher.classify(NSError(domain: "GEOErrorDomain", code: -3)) == .server)
        #expect(MapKitPlaceFetcher.classify(NSError(domain: NSCocoaErrorDomain, code: 4864)) == .server)
        struct Opaque: Error {}
        #expect(MapKitPlaceFetcher.classify(Opaque()) == .server)
    }

    /// Every failure kind has a retry schedule; only not-found has none.
    @Test func everyFailureKindHasARetrySchedule() {
        let delays = PlaceDirectory.Configuration.default.retryDelays
        for failure in PlaceFetchFailure.allCases {
            #expect(delays[failure] != nil, "\(failure)")
        }
        #expect(delays[.notFound] == [])
        #expect(delays[.offline] == [5, 20, 60, 180])
        #expect(delays[.timeout] == [10, 30, 90])
        #expect(delays[.transport] == [30, 90])
        #expect(delays[.throttled] == [60, 180])
        #expect(delays[.server] == [20, 60])
    }
}
