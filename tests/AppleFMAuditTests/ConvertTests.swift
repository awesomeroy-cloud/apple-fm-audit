import Foundation
import Testing
@testable import AppleFMAuditCore

@Suite("ConvertTests")
struct ConvertTests {
    @Test("Responses path detection")
    func testResponsesPath() {
        #expect(Convert.isResponsesPath("/v1/responses"))
        #expect(Convert.isResponsesPath("/responses"))
        #expect(Convert.isResponsesPath("/v1/responses?test=1"))
        #expect(!Convert.isResponsesPath("/v1/chat/completions"))
        #expect(!Convert.isResponsesPath("/v1/models"))
    }

    @Test("toChatRequest normalizes roles and flattens input")
    func testToChatRequest() {
        let payload: [String: Any] = [
            "model": "system",
            "instructions": "System prompt",
            "input": [
                [
                    "role": "developer",
                    "content": [
                        ["type": "input_text", "text": "Developer rule"]
                    ]
                ],
                [
                    "role": "user",
                    "content": "User question"
                ]
            ],
            "stream": true,
            "store": false
        ]

        let chat = Convert.toChatRequest(payload: payload)
        #expect((chat["model"] as? String) == "system")
        #expect((chat["stream"] as? Bool) == true)
        #expect(chat["store"] == nil)

        let messages = (chat["messages"] as? [[String: Any]]) ?? []
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "System prompt")
        #expect(messages[1]["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "Developer rule")
        #expect(messages[2]["role"] as? String == "user")
        #expect(messages[2]["content"] as? String == "User question")
    }

    @Test("chatToResponse maps chat completion to responses schema")
    func testChatToResponse() {
        let chat: [String: Any] = [
            "id": "chatcmpl-test1234",
            "model": "system",
            "created": 1700000000,
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "Hello World"
                    ]
                ]
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15
            ]
        ]

        let resp = Convert.chatToResponse(chat: chat)
        #expect(resp["object"] as? String == "response")
        #expect(resp["id"] as? String == "resp_test1234")
        #expect(resp["model"] as? String == "system")

        let output = (resp["output"] as? [[String: Any]]) ?? []
        #expect(output.count == 1)
        let content = (output[0]["content"] as? [[String: Any]]) ?? []
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "Hello World")

        let usage = resp["usage"] as? [String: Any]
        #expect(usage?["input_tokens"] as? Int == 10)
        #expect(usage?["output_tokens"] as? Int == 5)
        #expect(usage?["total_tokens"] as? Int == 15)
    }

    @Test("chatSSELineToResponseFrames generates proper SSE event stream")
    func testSSEFrames() {
        var state = ResponsesSSEState()

        let line1 = "data: {\"id\":\"chatcmpl-stream1\",\"model\":\"system\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n"
        let frames1 = Convert.chatSSELineToResponseFrames(line: line1, state: &state)
        #expect(frames1.count == 3)
        #expect(frames1[0].contains("event: response.created"))
        #expect(frames1[0].contains("\"created_at\":"))
        #expect(frames1[1].contains("event: response.output_item.added"))
        #expect(frames1[2].contains("event: response.output_text.delta"))
        #expect(frames1[2].contains("Hello"))

        let line2 = "data: {\"id\":\"chatcmpl-stream1\",\"model\":\"system\",\"choices\":[{\"delta\":{\"content\":\" World\"}}]}\n"
        let frames2 = Convert.chatSSELineToResponseFrames(line: line2, state: &state)
        #expect(frames2.count == 1)
        #expect(frames2[0].contains("event: response.output_text.delta"))
        #expect(frames2[0].contains(" World"))

        let lineDone = "data: [DONE]\n"
        let framesDone = Convert.chatSSELineToResponseFrames(line: lineDone, state: &state)
        #expect(framesDone.count == 2)
        #expect(framesDone[0].contains("event: response.output_item.done"))
        #expect(framesDone[1].contains("event: response.completed"))
        #expect(framesDone[1].contains("\"created_at\":"))
        #expect(state.completed)
    }
}
