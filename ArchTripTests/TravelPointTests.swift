import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Travel point settings (design v3): reading never fails on the setting and is apart
/// from the write-time bounds; the Event's own encoding and the editor's update leave it
/// alone; the two-field update carries nothing else; a saved search text is only ever the
/// user's own words; the save state follows the latest write's server reply; and a point
/// resolves from the setting before the Building, with no fallback for an unreadable one.
struct TravelPointTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let longID = String(repeating: "L", count: TravelPointSetting.placeIdMaxLength + 1)
    private let longQuery = String(repeating: "Q", count: TravelPointSetting.queryMaxLength + 1)

    private func event(_ id: String = "e1", buildingId: String? = nil, location: String = "", travelPoint: TravelPointSetting? = nil, updatedAt: Date? = nil) -> Event {
        Event(
            id: id, tripId: "trip", type: buildingId == nil ? .business : .architecture, title: "Fixture \(id)",
            startDate: date, endDate: date.addingTimeInterval(3_600), locationName: location, createdAt: date,
            updatedAt: updatedAt, buildingId: buildingId, travelPoint: travelPoint
        )
    }

    private func building(_ id: String, placeID: String? = nil) -> Building {
        Building(id: id, name: "Fixture building \(id)", createdAt: date, applePlaceId: placeID)
    }

    private func decode(travelPoint: Any?) throws -> Event {
        var fields = try Firestore.Encoder().encode(event())
        if let travelPoint { fields["travelPoint"] = travelPoint }
        return try Firestore.Decoder().decode(Event.self, from: fields)
    }

    // MARK: Reading never fails on the setting

    @Test func bothShapesDecodeVerbatim() throws {
        let place = try decode(travelPoint: ["kind": "place", "placeId": " fixture/Place-ID 0002 "])
        #expect(place.travelPoint == .place(id: " fixture/Place-ID 0002 "))
        let query = try decode(travelPoint: ["kind": "query", "query": "架空駅 北口"])
        #expect(query.travelPoint == .query("架空駅 北口"))
        #expect(try decode(travelPoint: nil).travelPoint == nil)
        #expect(place.isValid && query.isValid && place.travelPointIsWritable && query.travelPointIsWritable)
    }

    /// 128 / 200 bound writing only: a stored value beyond them reads verbatim, the Event
    /// stays valid and shown, and only saving is refused.
    @Test func storedValuesBeyondTheWriteBoundsStillRead() throws {
        let place = try decode(travelPoint: ["kind": "place", "placeId": longID])
        #expect(place.travelPoint == .place(id: longID))
        #expect(place.isValid && !place.travelPointIsWritable)
        #expect(place.travelPoint?.exceedsWriteLimit == true)
        let query = try decode(travelPoint: ["kind": "query", "query": longQuery])
        #expect(query.travelPoint == .query(longQuery))
        #expect(query.isValid && !query.travelPointIsWritable)
        #expect(TravelPointSetting.placeIdMaxLength == Building.applePlaceIdMaxLength)
        #expect(TravelPointSetting.queryMaxLength == Event.locationNameMaxLength)
    }

    @Test func invalidShapesReadAsUnreadableAndKeepTheEvent() throws {
        let cases: [(label: String, value: Any, reason: String)] = [
            ("string", "IFIXTURE", "not a map"),
            ("number", 12, "not a map"),
            ("array", ["kind", "place"], "not a map"),
            ("missing kind", ["placeId": "I1"], "missing kind"),
            ("kind not a string", ["kind": 1, "placeId": "I1"], "kind is not a string"),
            ("unknown kind", ["kind": "coordinate", "latitude": 43.0], "unknown kind"),
            ("place without id", ["kind": "place"], "invalid placeId"),
            ("place with empty id", ["kind": "place", "placeId": ""], "invalid placeId"),
            ("place with non-string id", ["kind": "place", "placeId": 5], "invalid placeId"),
            ("place with a name", ["kind": "place", "placeId": "I1", "name": "Fixture"], "unexpected keys"),
            ("both values", ["kind": "place", "placeId": "I1", "query": "x"], "unexpected keys"),
            ("query without text", ["kind": "query"], "invalid query"),
            ("query with empty text", ["kind": "query", "query": ""], "invalid query"),
            ("query with coordinates", ["kind": "query", "query": "x", "latitude": 1, "longitude": 2], "unexpected keys"),
        ]
        for item in cases {
            let event = try decode(travelPoint: item.value)
            #expect(event.travelPoint == .unreadable(reason: item.reason), "\(item.label)")
            #expect(event.isValid && !event.travelPointIsWritable, "\(item.label)")
            #expect(event.travelPoint?.exceedsWriteLimit == false, "\(item.label): unreadable is not a length problem")
        }
    }

    @Test func anUnreadableSettingIsNeverWrittenBack() {
        let setting = TravelPointSetting.unreadable(reason: "unexpected keys")
        #expect(setting.documentValue == nil && !setting.isWritable && setting.isUnreadable)
        #expect(throws: EncodingError.self) { try Firestore.Encoder().encode(setting) }
        #expect(throws: TravelPointUpdateError.notWritable) { try TravelPointUpdate.fields(setting: setting, createdAt: date) }
    }

    // MARK: The Event's own encoding and the editor's update leave it alone

    @Test func theEventEncodingLeavesTheTravelPointOut() throws {
        let fields = try Firestore.Encoder().encode(event(travelPoint: .place(id: "IFIXTURE")))
        #expect(fields["travelPoint"] == nil)
        #expect(Set(fields.keys) == ["id", "tripId", "type", "title", "startDate", "endDate", "locationName", "note", "createdAt", "updatedAt"])
        #expect(!Event.optionalFields.contains("travelPoint"))
        // A decoded Event with an unreadable setting still encodes: the editor re-encodes what it loaded.
        let unreadable = try Firestore.Encoder().encode(event(travelPoint: .unreadable(reason: "x")))
        #expect(unreadable["travelPoint"] == nil)
        // The setting's own encoding is the document map, and only that.
        #expect(try Firestore.Encoder().encode(TravelPointSetting.place(id: "IFIXTURE")) as? [String: String] == ["kind": "place", "placeId": "IFIXTURE"])
        #expect(try Firestore.Encoder().encode(TravelPointSetting.query("架空駅")) as? [String: String] == ["kind": "query", "query": "架空駅"])
    }

    @Test func theEditorUpdateNeitherResendsNorDeletesTheTravelPoint() throws {
        let stored = event(travelPoint: .place(id: "IFIXTURE"))
        var edited = stored
        edited.title = "Fixture edited"
        edited.travelPoint = nil // the editor's draft never carries it
        let fields = try DocumentUpdate.fields(for: edited, replacing: stored)
        #expect(fields["travelPoint"] == nil, "no delete for a field the editor does not own")
        #expect(fields["title"] as? String == "Fixture edited")
        #expect(try DocumentUpdate.fields(for: stored, replacing: stored)["travelPoint"] == nil, "never resent")
        #expect(try DocumentUpdate.fields(for: edited, replacing: event(travelPoint: .place(id: longID)))["travelPoint"] == nil)
        #expect(try DocumentUpdate.fields(for: edited, replacing: event(travelPoint: .unreadable(reason: "x")))["travelPoint"] == nil)
    }

    // MARK: The two-field update

    @Test func theUpdateCarriesOnlyTheTravelPointAndUpdatedAt() throws {
        let now = date.addingTimeInterval(120)
        let place = try TravelPointUpdate.fields(setting: .place(id: "IFIXTURE"), createdAt: date, now: now)
        #expect(Set(place.keys) == ["travelPoint", "updatedAt"])
        #expect(place["travelPoint"] as? [String: String] == ["kind": "place", "placeId": "IFIXTURE"])
        #expect((place["updatedAt"] as? Timestamp)?.dateValue() == now)
        let query = try TravelPointUpdate.fields(setting: .query("架空駅"), createdAt: date, now: now)
        #expect(Set(query.keys) == ["travelPoint", "updatedAt"])
        #expect(query["travelPoint"] as? [String: String] == ["kind": "query", "query": "架空駅"])
        let clear = try TravelPointUpdate.fields(setting: nil, createdAt: date, now: now)
        #expect(Set(clear.keys) == ["travelPoint", "updatedAt"])
        #expect(clear["travelPoint"] is FieldValue)
        // updatedAt never precedes createdAt (the rules require it).
        let early = try TravelPointUpdate.fields(setting: nil, createdAt: date, now: date.addingTimeInterval(-60))
        #expect((early["updatedAt"] as? Timestamp)?.dateValue() == date)
    }

    @Test func anUnwritableSettingIsNotSent() throws {
        #expect(throws: TravelPointUpdateError.notWritable) { try TravelPointUpdate.fields(setting: .place(id: longID), createdAt: date) }
        #expect(throws: TravelPointUpdateError.notWritable) { try TravelPointUpdate.fields(setting: .query(longQuery), createdAt: date) }
        #expect(throws: TravelPointUpdateError.notWritable) { try TravelPointUpdate.fields(setting: .place(id: ""), createdAt: date) }
        #expect(throws: TravelPointUpdateError.notWritable) { try TravelPointUpdate.fields(setting: .query(""), createdAt: date) }
        let atBound = try TravelPointUpdate.fields(setting: .place(id: String(repeating: "A", count: TravelPointSetting.placeIdMaxLength)), createdAt: date)
        #expect(atBound["travelPoint"] != nil)
        #expect(try TravelPointUpdate.fields(setting: .query(String(repeating: "Q", count: TravelPointSetting.queryMaxLength)), createdAt: date)["travelPoint"] != nil)
    }

    // MARK: Where a saved search text may come from (design §4.2, Q1–Q14)

    /// The separate "search text to save" field starts with the user's own words only.
    @Test func theSaveFieldStartsWithTheUsersOwnTextOnly() {
        let rows: [(label: String, source: TravelQuerySource, searchText: String, prefill: String)] = [
            ("Q1 typed into an empty field", .empty, "架空駅 北口", "架空駅 北口"),
            ("Q2 location left as it was", .appText("Fixture hall"), "Fixture hall", ""),
            ("Q3 building name left as it was", .appText("Fixture building"), "Fixture building", ""),
            ("Q4 result text left as it was", .candidate("架空市役所"), "架空市役所", ""),
            ("Q5a location edited", .appText("Fixture hall"), "Fixture hall east gate", "Fixture hall east gate"),
            ("Q5b result text edited", .candidate("架空市役所"), "架空市役所 東口", ""),
            ("Q5b result text replaced entirely", .candidate("架空市役所"), "my own words", ""),
            ("Q6 edited then restored", .appText("Fixture hall"), "Fixture hall", ""),
            ("Q7 retyped the same words", .appText("Fixture hall"), " Fixture hall ", ""),
            ("Q8 saved text unchanged", .saved("架空駅"), "架空駅", "架空駅"),
            ("Q9 saved text edited", .saved("架空駅"), "架空駅 南口", "架空駅 南口"),
            ("Q12 blanks only", .empty, "   ", ""),
        ]
        for row in rows {
            #expect(TravelQueryProvenance.prefill(source: row.source, searchText: row.searchText) == row.prefill, "\(row.label)")
        }
    }

    @Test func aResultWithAnIDDecidesItself() {
        func result(identifier: String?) -> PlaceResult {
            PlaceResult(kind: .pointOfInterest, name: "Fixture", address: "架空県", latitude: 43, longitude: 141, identifier: identifier)
        }
        let atBound = String(repeating: "A", count: TravelPointSetting.placeIdMaxLength)
        #expect(TravelQueryProvenance.outcome(for: result(identifier: "IFIXTURE")) == .savePlace(id: "IFIXTURE"), "Q10")
        #expect(TravelQueryProvenance.outcome(for: result(identifier: atBound)) == .savePlace(id: atBound))
        #expect(TravelQueryProvenance.outcome(for: result(identifier: longID)) == .thisSearchOnly(.identifierTooLong), "Q14")
        #expect(TravelQueryProvenance.outcome(for: result(identifier: nil)) == nil, "no ID: the user decides about the search text")
        #expect(TravelQueryProvenance.outcome(for: result(identifier: "")) == nil)
    }

    @Test func theSaveFieldIsCheckedBeforeSaving() {
        #expect(TravelQueryProvenance.issue("") == .empty)
        #expect(TravelQueryProvenance.issue("  \n") == .empty)
        #expect(TravelQueryProvenance.issue(longQuery) == .tooLong, "Q13")
        #expect(TravelQueryProvenance.issue(String(repeating: "Q", count: TravelPointSetting.queryMaxLength)) == nil)
        #expect(TravelQueryProvenance.issue(" 架空駅 ") == nil)
    }

    /// Q11: there is no path from a result's name or address into a saved query. The
    /// sentinels sit in the result and in the picker's search field and never in what
    /// could be saved; a result with an ID yields the ID alone.
    @Test func aResultsNameAndAddressNeverReachTheSavedQuery() throws {
        let name = "SENTINEL-NAME"
        let address = "SENTINEL-ADDRESS 架空県"
        let result = PlaceResult(kind: .address, name: name, address: address, latitude: 43, longitude: 141, identifier: nil)
        #expect(TravelQueryProvenance.outcome(for: result) == nil)
        let endpoint = TravelEndpoint.candidate(result)
        #expect(endpoint.querySource == .candidate(name))
        for searchText in [name, address, "\(name) edited", "\(address) 1-2"] {
            #expect(TravelQueryProvenance.prefill(source: endpoint.querySource, searchText: searchText) == "", "\(searchText)")
        }
        let fields = try TravelPointUpdate.fields(setting: .query("my words"), createdAt: date)
        let stored = try #require(fields["travelPoint"] as? [String: String])
        #expect(stored == ["kind": "query", "query": "my words"])
        #expect(!stored.values.joined().contains("SENTINEL"))
        let withID = PlaceResult(kind: .pointOfInterest, name: name, address: address, latitude: 43, longitude: 141, identifier: "IFIXTURE")
        #expect(TravelQueryProvenance.outcome(for: withID) == .savePlace(id: "IFIXTURE"))
    }

    // MARK: Save state

    /// "Syncing" from the send, "saved" or "save failed" from the server's reply to the
    /// Event's latest write only: a late reply to an earlier write changes nothing.
    @MainActor
    @Test func onlyTheLatestWriteChangesTheSaveState() {
        let tracker = TravelPointWriteTracker()
        #expect(tracker.status(for: "e1") == nil)
        let first = tracker.begin(eventID: "e1")
        #expect(tracker.status(for: "e1") == .syncing)
        let second = tracker.begin(eventID: "e1")
        #expect(first != second && tracker.status(for: "e1") == .syncing)
        tracker.finish(eventID: "e1", token: first, error: NSError(domain: "FIRFirestoreErrorDomain", code: 7))
        #expect(tracker.status(for: "e1") == .syncing, "the earlier write's late rejection does not touch the newer one")
        tracker.finish(eventID: "e1", token: second, error: nil)
        #expect(tracker.status(for: "e1") == .saved)
        tracker.finish(eventID: "e1", token: first, error: nil)
        #expect(tracker.status(for: "e1") == .saved)
        let third = tracker.begin(eventID: "e1")
        let other = tracker.begin(eventID: "e2")
        tracker.finish(eventID: "e1", token: third, error: NSError(domain: "FIRFirestoreErrorDomain", code: 5))
        #expect(tracker.status(for: "e1") == .failed && tracker.status(for: "e2") == .syncing)
        tracker.finish(eventID: "e2", token: other, error: nil)
        #expect(tracker.status(for: "e2") == .saved && tracker.status(for: "e1") == .failed)
    }

    // MARK: Where a point resolves from

    /// The explicit choice comes first and is kept whatever happens to the Building (R1);
    /// the Building's place stays reachable as the default to go back to.
    @Test func theSavedPointComesBeforeTheBuildingsPlace() {
        let linked = building("b1", placeID: "IBUILDING000000001")
        let saved = event("a", buildingId: "b1", travelPoint: .place(id: "ISAVED00000000001"))
        let expectedDefault = TravelEndpoint.linkedPlace(placeID: "IBUILDING000000001", buildingID: "b1", buildingUpdatedAt: date)
        #expect(TravelEndpoint.resolve(event: saved, buildings: [linked]) == .savedPlace(placeID: "ISAVED00000000001"))
        #expect(TravelEndpoint.resolve(event: saved, buildings: [linked]).isUsable)
        #expect(TravelEndpoint.buildingDefault(event: saved, buildings: [linked]) == expectedDefault)
        #expect(TravelEndpoint.resolve(event: saved, buildings: [building("b1")]) == .savedPlace(placeID: "ISAVED00000000001"), "Building unlinked")
        #expect(TravelEndpoint.resolve(event: saved, buildings: []) == .savedPlace(placeID: "ISAVED00000000001"), "Building gone")
        #expect(TravelEndpoint.buildingDefault(event: saved, buildings: []) == nil)
        let plain = event("a", buildingId: "b1")
        #expect(TravelEndpoint.resolve(event: plain, buildings: [linked]) == expectedDefault, "without a setting, the Building's place as before")
        #expect(TravelEndpoint.resolve(event: event("a", location: "Fixture hall"), buildings: []) == .unresolved(hint: "Fixture hall"))
    }

    @Test func aSavedQueryRestoresTheTextAndChoosesNothing() {
        let endpoint = TravelEndpoint.resolve(event: event("a", location: "Fixture hall", travelPoint: .query("架空駅")), buildings: [])
        #expect(endpoint == .savedQuery("架空駅"))
        #expect(!endpoint.isUsable)
        #expect(endpoint.hint == "架空駅" && endpoint.querySource == .saved("架空駅"))
    }

    @Test func anUnreadableSettingNeverFallsBackToTheBuilding() {
        let linked = building("b1", placeID: "IBUILDING000000001")
        let broken = event("a", buildingId: "b1", location: "Fixture hall", travelPoint: .unreadable(reason: "unexpected keys"))
        let endpoint = TravelEndpoint.resolve(event: broken, buildings: [linked])
        #expect(endpoint == .unreadableSetting(reason: "unexpected keys"))
        #expect(!endpoint.isUsable && endpoint.hint == "" && endpoint.querySource == .empty)
        #expect(TravelEndpoint.buildingDefault(event: broken, buildings: [linked]) != nil, "the way back exists, but only by the user's clearing")
    }

    @Test func theSearchFieldsProvenanceFollowsTheEndpoint() {
        #expect(TravelEndpoint.unresolved(hint: "Fixture hall").querySource == .appText("Fixture hall"))
        #expect(TravelEndpoint.unresolved(hint: "").querySource == .empty)
        #expect(TravelEndpoint.linkedPlace(placeID: "I1", buildingID: "b1", buildingUpdatedAt: date).querySource == .empty)
        #expect(TravelEndpoint.savedPlace(placeID: "I1").querySource == .empty)
        let named = PlaceResult(kind: .pointOfInterest, name: "架空市役所", address: "架空県", latitude: 43, longitude: 141, identifier: nil)
        let addressOnly = PlaceResult(kind: .address, name: "", address: "架空県架空市", latitude: 43, longitude: 141, identifier: nil)
        #expect(TravelEndpoint.candidate(named).querySource == .candidate("架空市役所"))
        #expect(TravelEndpoint.candidate(addressOnly).querySource == .candidate("架空県架空市"))
    }

    /// A changed setting, or the `updatedAt` its update bumps, changes the key, so the
    /// old result is shown as stale; an unchanged one keeps it.
    @Test func aChangedSettingMakesTheKeyStale() {
        func key(_ from: TravelEndpoint, updatedAt: Date) -> TravelRequestKey {
            TravelRequestKey(
                fromEventID: "a", fromEventUpdatedAt: updatedAt, from: from,
                toEventID: "b", toEventUpdatedAt: date, to: .savedPlace(placeID: "I2"),
                mode: .car, anchor: .departAt(date)
            )
        }
        let linked = TravelEndpoint.linkedPlace(placeID: "I1", buildingID: "b1", buildingUpdatedAt: date)
        let before = key(linked, updatedAt: date)
        #expect(before != key(.savedPlace(placeID: "I9"), updatedAt: date), "the point changed")
        #expect(before != key(linked, updatedAt: date.addingTimeInterval(1)), "updatedAt changed by the two-field update")
        #expect(before == key(linked, updatedAt: date))
    }

    // MARK: A picked result is bound to the setting it was picked against (PR #17 review)

    private let picked = PlaceResult(kind: .address, name: "", address: "架空県架空市架空町一丁目", latitude: 43.1, longitude: 141.1, identifier: nil)
    private let pickedWithID = PlaceResult(kind: .pointOfInterest, name: "Fixture hall", address: "", latitude: 43.1, longitude: 141.1, identifier: "IPICKED0000000001")

    private func shown(_ candidate: TravelPickedCandidate?, for event: Event) -> TravelEndpoint {
        TravelEndpoint.shown(stored: TravelEndpoint.resolve(event: event, buildings: []), candidate: candidate, event: event)
    }

    /// The user's own query save: the candidate stays while the Event still holds what it
    /// held at the pick (write not reflected yet) and once it holds what the pick requested.
    @Test func aQuerySaveKeepsItsCandidateThroughTheLocalReflection() {
        let candidate = TravelPickedCandidate(result: picked, outcome: .saveQuery("架空駅"), eventID: "a", settingAtPick: nil)
        #expect(candidate.requestedSetting == .query("架空駅"))
        let before = event("a", location: "Fixture hall")
        #expect(candidate.applies(to: before) && shown(candidate, for: before) == .candidate(picked))
        let reflected = event("a", location: "Fixture hall", travelPoint: .query("架空駅"), updatedAt: date.addingTimeInterval(1))
        #expect(candidate.applies(to: reflected) && shown(candidate, for: reflected) == .candidate(picked))
    }

    /// A query change, a place change, a clear or a broken setting arriving from elsewhere
    /// drops the candidate: what the listener delivers is shown.
    @Test func aCandidateIsDroppedWhenAnotherSettingArrives() {
        let candidate = TravelPickedCandidate(result: picked, outcome: .saveQuery("架空駅"), eventID: "a", settingAtPick: .place(id: "IOLD0000000000001"))
        let arrivals: [(label: String, setting: TravelPointSetting?)] = [
            ("query changed elsewhere", .query("別の駅")),
            ("place changed elsewhere", .place(id: "INEW0000000000001")),
            ("cleared elsewhere", nil),
            ("broken elsewhere", .unreadable(reason: "unexpected keys")),
        ]
        for arrival in arrivals {
            let event = event("a", travelPoint: arrival.setting)
            #expect(!candidate.applies(to: event), "\(arrival.label)")
            #expect(shown(candidate, for: event) == TravelEndpoint.resolve(event: event, buildings: []), "\(arrival.label): the listener's setting shows, not the old candidate")
        }
        #expect(!candidate.applies(to: event("b", travelPoint: .place(id: "IOLD0000000000001"))), "another Event")
        #expect(shown(candidate, for: event("a", travelPoint: .query("架空駅"))) == .candidate(picked), "the requested setting keeps it")
    }

    @Test func aPlaceSaveShowsTheStoredRowOnceReflected() {
        let candidate = TravelPickedCandidate(result: pickedWithID, outcome: .savePlace(id: "IPICKED0000000001"), eventID: "a", settingAtPick: nil)
        #expect(shown(candidate, for: event("a")) == .candidate(pickedWithID), "until the write is reflected, the picked result shows")
        #expect(shown(candidate, for: event("a", travelPoint: .place(id: "IPICKED0000000001"))) == .savedPlace(placeID: "IPICKED0000000001"), "then the saved place, fetched by its ID")
        #expect(shown(candidate, for: event("a", travelPoint: .place(id: "IOTHER00000000001"))) == .savedPlace(placeID: "IOTHER00000000001"), "a different place from elsewhere is shown, not the candidate")
    }

    @Test func aThisSearchOnlyCandidateFollowsOnlyTheSettingItWasPickedAgainst() {
        let candidate = TravelPickedCandidate(result: picked, outcome: .thisSearchOnly(.notSaved), eventID: "a", settingAtPick: .query("架空駅"))
        #expect(candidate.requestedSetting == .query("架空駅"))
        #expect(candidate.applies(to: event("a", travelPoint: .query("架空駅"))))
        #expect(candidate.applies(to: event("a", travelPoint: .query("架空駅"), updatedAt: date.addingTimeInterval(60))), "another field edited: the setting is unchanged")
        #expect(!candidate.applies(to: event("a")), "cleared elsewhere")
        #expect(!candidate.applies(to: event("a", travelPoint: .place(id: "I1"))), "replaced elsewhere")
        #expect(!candidate.applies(to: event("a", travelPoint: .unreadable(reason: "x"))), "broken elsewhere")
    }

    /// A rejected save restores the setting the result was picked against, which this
    /// binding alone cannot tell from a write not reflected yet; the screen drops the
    /// candidate on the write's failed state, after which the restored setting shows.
    @Test func aRejectedSaveRestoresTheSettingTheCandidateWasPickedAgainst() {
        let candidate = TravelPickedCandidate(result: pickedWithID, outcome: .savePlace(id: "IPICKED0000000001"), eventID: "a", settingAtPick: .place(id: "IOLD0000000000001"))
        let restored = event("a", travelPoint: .place(id: "IOLD0000000000001"))
        #expect(candidate.applies(to: restored))
        #expect(shown(nil, for: restored) == .savedPlace(placeID: "IOLD0000000000001"), "once dropped, the restored setting is what shows")
    }

    /// Dropping a candidate changes the endpoint and so the key: a result computed with
    /// the old candidate is shown as stale.
    @Test func droppingACandidateMakesTheKeyStale() {
        func key(_ to: TravelEndpoint) -> TravelRequestKey {
            TravelRequestKey(
                fromEventID: "a", fromEventUpdatedAt: date, from: .savedPlace(placeID: "I1"),
                toEventID: "b", toEventUpdatedAt: date, to: to, mode: .car, anchor: .departAt(date)
            )
        }
        let candidate = TravelPickedCandidate(result: picked, outcome: .thisSearchOnly(.notSaved), eventID: "b", settingAtPick: nil)
        let before = shown(candidate, for: event("b", location: "Fixture hall"))
        let after = shown(candidate, for: event("b", location: "Fixture hall", travelPoint: .query("架空駅")))
        #expect(before == .candidate(picked) && after == .savedQuery("架空駅"))
        #expect(key(before) != key(after))
    }
}
