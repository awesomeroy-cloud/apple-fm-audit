import Foundation
import Testing
@testable import AppleFMAuditCore

@Suite("PCCTests")
struct PCCTests {
    @Test("Model identification and aliases")
    func testAliases() {
        #expect(PCC.isPCCModel("pcc"))
        #expect(PCC.isPCCModel("PrivateCloudCompute"))
        #expect(PCC.isPCCModel("private-cloud-compute"))
        #expect(PCC.isPCCModel("afm-pcc"))
        #expect(!PCC.isPCCModel("system"))
        #expect(!PCC.isPCCModel(nil))
    }

    @Test("Availability detection across health payloads")
    func testAvailability() {
        let unsupported = PCC.pccAvailability(health: [
            "reachable": true,
            "models": [["name": "system", "available": true]]
        ])
        #expect(unsupported.state == "unsupported")

        let available = PCC.pccAvailability(health: [
            "reachable": true,
            "models": [
                ["name": "system", "available": true],
                ["name": "pcc", "available": true]
            ]
        ])
        #expect(available.state == "available")

        let ineligible = PCC.pccAvailability(health: [
            "reachable": true,
            "models": [
                ["name": "pcc", "available": false, "reason": "deviceNotEligible"]
            ]
        ])
        #expect(ineligible.state == "deviceNotEligible")

        let notReady = PCC.pccAvailability(health: [
            "reachable": true,
            "models": [
                ["name": "pcc", "available": false, "reason": "PCC isn't ready to serve requests (systemNotReady)"]
            ]
        ])
        #expect(notReady.state == "systemNotReady")
    }

    @Test("Choose model resolves fallback correctly")
    func testChooseModel() {
        let (sysModel, sysNote) = PCC.chooseModel(
            requested: "system",
            health: ["reachable": true, "models": [["name": "system", "available": true]]]
        )
        #expect(sysModel == "system")
        #expect(sysNote == nil)

        let (fallbackModel, fallbackNote) = PCC.chooseModel(
            requested: "pcc",
            health: ["reachable": true, "models": [["name": "system", "available": true]]]
        )
        #expect(fallbackModel == "system")
        #expect(fallbackNote?.contains("unsupported") == true)

        let (keptModel, keptNote) = PCC.chooseModel(
            requested: "pcc",
            health: ["reachable": true, "models": [["name": "pcc", "available": true]]]
        )
        #expect(keptModel == "pcc")
        #expect(keptNote == nil)
    }

    @Test("Network failure detection distinguishes network vs unknown model")
    func testNetworkFailure() {
        let isNet = PCC.isNetworkFailure(
            status: 503,
            resBody: "{\"error\":{\"message\":\"NetworkFailureError: connection unavailable\"}}",
            error: nil
        )
        #expect(isNet)

        let isUnknown = PCC.isNetworkFailure(
            status: 400,
            resBody: "{\"error\":{\"message\":\"Unknown model 'pcc'. Available models: system\"}}",
            error: nil
        )
        #expect(!isUnknown)
    }

    @Test("setJSONModel updates model in JSON payload")
    func testSetJSONModel() {
        let input = "{\"model\":\"pcc\",\"messages\":[]}".data(using: .utf8)!
        let output = PCC.setJSONModel(body: input, model: "system")
        let decoded = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        #expect((decoded?["model"] as? String) == "system")
    }
}
