import Foundation
import Testing
@testable import vinnyfin

/// What the app says about a server's error answers.
struct ServerErrorTests {
    private func message(_ status: Int, _ body: String = "") -> String {
        JellyfinError.http(status: status, body: body).localizedDescription
    }

    @Test func saysWhatEachKindOfStatusMeans() {
        #expect(message(500) == "The server ran into a problem (HTTP 500). If it keeps happening, the server's log says why.")
        #expect(message(501).hasPrefix("The server ran into a problem (HTTP 501)."))
        for status in [502, 503, 504] {
            #expect(message(status) == "The server can't be reached right now (HTTP \(status)). It may be restarting or still starting up.")
        }
        #expect(message(401) == "The server no longer accepts this sign-in (HTTP 401). Sign in again to carry on.")
        #expect(message(403) == "This account isn't allowed to do that on the server (HTTP 403). An administrator can allow it in Jellyfin's dashboard.")
        #expect(message(404) == "The server couldn't find it (HTTP 404). It may have been removed from the library.")
        #expect(message(429) == "The server is getting too many requests (HTTP 429). Wait a moment, then try again.")
        #expect(message(400) == "The server turned the request down (HTTP 400).")
        #expect(message(302) == "The server gave an answer vinnyfin didn't expect (HTTP 302).")
    }

    @Test func quotesAProblemReportsDetail() {
        let report = """
            {"type":"https://tools.ietf.org/html/rfc9110#section-15.6.1","title":"An error occurred while processing your request.",\
            "status":500,"detail":"The database is locked.","traceId":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"}
            """
        #expect(message(500, report)
            == "The server ran into a problem (HTTP 500). It said: “The database is locked.” If it keeps happening, the server's log says why.")
    }

    @Test func quotesAProblemReportsTitleOnlyWhenItSaysMoreThanTheStatus() {
        let notFound = #"{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.5","title":"Not Found","status":404,"traceId":"00-1"}"#
        #expect(message(404, notFound) == message(404))
        let stock = #"{"title":"An error occurred while processing your request.","status":500}"#
        #expect(message(500, stock) == message(500))
        let validation = #"{"title":"One or more validation errors occurred.","status":400,"errors":{"userId":["The value 'x' is not valid."]}}"#
        #expect(message(400, validation) == "The server turned the request down (HTTP 400). It said: “One or more validation errors occurred.”")
    }

    @Test func neverShowsAWebPage() {
        let page = """
            <!DOCTYPE html>
            <html><head><title>502 Bad Gateway</title></head>
            <body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx/1.25.3</center></body></html>
            """
        #expect(message(502, page) == message(502))
        #expect(!message(500, "<html><body>Internal Server Error</body></html>").contains("<"))
        #expect(JellyfinError.serverExplanation(in: "  <h1>Down for maintenance</h1>", status: 503) == nil)
    }

    @Test func saysJustTheStatusForAnEmptyOrStockBody() {
        #expect(JellyfinError.serverExplanation(in: "", status: 500) == nil)
        #expect(JellyfinError.serverExplanation(in: "  \n ", status: 500) == nil)
        // Jellyfin's answer to an exception outside a development build.
        #expect(message(500, "Error processing request.") == message(500))
        #expect(JellyfinError.serverExplanation(in: "Internal Server Error", status: 500) == nil)
    }

    @Test func quotesAJSONStringOrAShortLineOfText() {
        #expect(message(400, #""Invalid segment provider""#)
            == "The server turned the request down (HTTP 400). It said: “Invalid segment provider.”")
        #expect(JellyfinError.serverExplanation(in: "upstream connect error or disconnect/reset before headers", status: 503)
            == "upstream connect error or disconnect/reset before headers.")
        #expect(JellyfinError.serverExplanation(in: "Library is still scanning!", status: 503) == "Library is still scanning!")
        // Longer text, or text over several lines, is more likely a dump than an explanation.
        #expect(JellyfinError.serverExplanation(in: String(repeating: "word ", count: 60), status: 500) == nil)
        #expect(JellyfinError.serverExplanation(in: "System.Exception: boom\n   at Jellyfin.Api.Something()", status: 500) == nil)
    }

    @Test func shortensALongExplanationOntoOneLine() {
        let detail = String(repeating: "a", count: 300)
        let explanation = JellyfinError.serverExplanation(in: #"{"detail":"\#(detail)"}"#, status: 500)
        #expect(explanation?.count == 200)
        #expect(explanation?.hasSuffix("…") == true)
        #expect(JellyfinError.serverExplanation(in: #"{"detail":"Two\n  lines"}"#, status: 500) == "Two lines.")
    }

    @Test func aTruncatedOrOtherJSONBodySaysJustTheStatus() {
        #expect(JellyfinError.serverExplanation(in: #"{"detail":"The data"#, status: 500) == nil)
        #expect(JellyfinError.serverExplanation(in: #"["a","b"]"#, status: 500) == nil)
        #expect(JellyfinError.serverExplanation(in: #"{"traceId":"00-1"}"#, status: 500) == nil)
    }
}
