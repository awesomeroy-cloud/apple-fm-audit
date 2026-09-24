import Foundation
import AsyncHTTPClient
import Hummingbird
import HTTPTypes

public struct AppConfiguration: Sendable {
    public let listenHost: String
    public let listenPort: Int
    public let upstreamHost: String
    public let upstreamPort: Int
    public let dbPath: String
    public let staticDir: String
    public let fmBin: String?

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 1977,
        upstreamHost: String = "127.0.0.1",
        upstreamPort: Int = 1976,
        dbPath: String,
        staticDir: String,
        fmBin: String? = nil
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.dbPath = dbPath
        self.staticDir = staticDir
        self.fmBin = fmBin
    }
}

public struct DynamicCORSMiddleware<Context: RequestContext>: RouterMiddleware {
    public init() {}

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let origin = request.headers[.origin] else {
            return try await next(request, context)
        }

        if request.method == .options {
            var headers = HTTPFields()
            headers[.accessControlAllowOrigin] = origin
            headers[.accessControlAllowMethods] = "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD"
            let reqHeaders = request.headers[HTTPField.Name("access-control-request-headers") ?? .authorization] ?? "*"
            headers[.accessControlAllowHeaders] = reqHeaders
            headers[.accessControlAllowCredentials] = "true"
            headers[.accessControlMaxAge] = "86400"
            headers[values: .vary].append("Origin")
            return Response(status: .noContent, headers: headers, body: .init())
        }

        do {
            var response = try await next(request, context)
            response.headers[.accessControlAllowOrigin] = origin
            response.headers[.accessControlAllowCredentials] = "true"
            response.headers[values: .vary].append("Origin")
            return response
        } catch let httpError as HTTPResponseError {
            var response = try httpError.response(from: request, context: context)
            response.headers[.accessControlAllowOrigin] = origin
            response.headers[.accessControlAllowCredentials] = "true"
            response.headers[values: .vary].append("Origin")
            return response
        } catch {
            var headers = HTTPFields()
            headers[.accessControlAllowOrigin] = origin
            headers[.accessControlAllowCredentials] = "true"
            headers[.contentType] = "application/json; charset=utf-8"
            headers[values: .vary].append("Origin")
            let errBody = "{\"error\":{\"message\":\"\(error.localizedDescription)\",\"type\":\"internal_error\"}}"
            return Response(status: .internalServerError, headers: headers, body: .init(byteBuffer: ByteBuffer(string: errBody)))
        }
    }
}

public enum AppBuilder {
    public static func buildRouter(
        config: AppConfiguration,
        store: Store,
        client: HTTPClient
    ) -> Router<BasicRequestContext> {
        let router = Router()

        router.add(middleware: DynamicCORSMiddleware())

        let auditRoutes = AuditRoutes(
            store: store,
            client: client,
            listenHost: config.listenHost,
            listenPort: config.listenPort,
            upstreamHost: config.upstreamHost,
            upstreamPort: config.upstreamPort,
            dbPath: config.dbPath,
            staticDir: config.staticDir,
            fmBin: config.fmBin
        )

        let proxyHandler = ProxyHandler(
            client: client,
            upstreamHost: config.upstreamHost,
            upstreamPort: config.upstreamPort,
            store: store
        )

        // Static files
        router.get("/", use: auditRoutes.index)
        router.get("/app.css", use: auditRoutes.css)
        router.get("/app.js", use: auditRoutes.js)
        router.get("/favicon.ico", use: auditRoutes.favicon)
        router.get("/favicon.svg", use: auditRoutes.favicon)

        // Audit REST API
        router.get("/_audit/meta", use: auditRoutes.meta)
        router.get("/_audit/status", use: auditRoutes.status)
        router.get("/_audit/license", use: auditRoutes.license)
        router.get("/_audit/quota", use: auditRoutes.quota)
        router.get("/_audit/calls", use: auditRoutes.listCalls)
        router.get("/_audit/calls/{id}", use: auditRoutes.getCall)
        router.delete("/_audit/calls", use: auditRoutes.clearCalls)

        // Native TTS
        router.post("/v1/audio/speech", use: auditRoutes.speech)

        // Reverse Proxy Catch-all
        let proxyMethods: [HTTPRequest.Method] = [.get, .post, .put, .patch, .delete, .head]
        for m in proxyMethods {
            router.on("**", method: m, use: proxyHandler.handle)
            router.on("v1/**", method: m, use: proxyHandler.handle)
        }

        return router
    }

    public static func buildApplication(
        config: AppConfiguration,
        store: Store,
        client: HTTPClient
    ) -> some ApplicationProtocol {
        let router = buildRouter(config: config, store: store, client: client)
        return Application(
            router: router,
            configuration: .init(address: .hostname(config.listenHost, port: config.listenPort))
        )
    }
}
