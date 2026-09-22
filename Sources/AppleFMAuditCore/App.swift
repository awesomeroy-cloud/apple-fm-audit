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

public enum AppBuilder {
    public static func buildRouter(
        config: AppConfiguration,
        store: Store,
        client: HTTPClient
    ) -> Router<BasicRequestContext> {
        let router = Router()

        let corsHeaders: [HTTPField.Name] = [
            .accept,
            .authorization,
            .contentType,
            .origin,
            HTTPField.Name("OpenAI-Beta") ?? .authorization
        ]

        router.add(
            middleware: CORSMiddleware(
                allowOrigin: .originBased,
                allowHeaders: corsHeaders,
                allowMethods: [.get, .post, .put, .patch, .delete, .options, .head],
                maxAge: .seconds(600)
            )
        )

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
