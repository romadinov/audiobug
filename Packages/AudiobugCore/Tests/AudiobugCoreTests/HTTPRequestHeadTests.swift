import Foundation
import Testing
@testable import AudiobugCore

struct HTTPRequestHeadTests {
    @Test func parsesRequestLineQueryAndHeaders() {
        let head = HTTPRequestHead("PUT /upload/Old%20Man's%20War.m4b?folder=Sci%20Fi%2FScalzi&x=a+b HTTP/1.1\r\nHost: 1.2.3.4:8080\r\nContent-Length:  1234\r\nExpect: 100-continue")
        #expect(head?.method == "PUT")
        #expect(head?.path == "/upload/Old Man's War.m4b")
        #expect(head?.query == ["folder": "Sci Fi/Scalzi", "x": "a b"])
        #expect(head?.headers["host"] == "1.2.3.4:8080")
        #expect(head?.contentLength == 1234)
        #expect(head?.expectsContinue == true)
    }

    @Test func plainGet() {
        let head = HTTPRequestHead("GET / HTTP/1.1\r\nHost: x")
        #expect(head?.method == "GET")
        #expect(head?.path == "/")
        #expect(head?.query == [:])
        #expect(head?.contentLength == nil)
        #expect(head?.expectsContinue == false)
        #expect(HTTPRequestHead("") == nil)
        #expect(HTTPRequestHead("GET") == nil)
    }

    @Test func safeNames() {
        #expect(HTTPRequestHead.safeFileName("../../etc/passwd") == "passwd")
        #expect(HTTPRequestHead.safeFileName(".hidden.m4b") == "hidden.m4b")
        #expect(HTTPRequestHead.safeFileName("  Emma.m4b ") == "Emma.m4b")
        #expect(HTTPRequestHead.safeFileName("...") == nil)
        #expect(HTTPRequestHead.safeFolder("") == "")
        #expect(HTTPRequestHead.safeFolder("/Fiction/ Scalzi /") == "Fiction/Scalzi")
        #expect(HTTPRequestHead.safeFolder("../Books") == nil)
        #expect(HTTPRequestHead.safeFolder("Fiction/.git") == nil)
    }
}
