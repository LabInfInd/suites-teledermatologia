from urllib.parse import urlsplit

from starlette.responses import JSONResponse

from app.config import get_settings


class SafetyMiddleware:
    """Limiti prima del parser multipart; controllo dell'origine e intestazioni locali."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = {key.decode("latin1").lower(): value.decode("latin1") for key, value in scope["headers"]}
        path, method = scope["path"], scope["method"]
        api = path.startswith("/api/")
        settings = get_settings()

        async def reject(status, detail):
            body = {"error":{"code":{413:"payload_too_large",403:"forbidden"}.get(status,"invalid_request"),"message":detail}} if path.startswith("/v1/") else {"detail":detail}
            await JSONResponse(body, status_code=status)(scope, receive, send)

        # L'interfaccia e i file sono serviti solo sugli indirizzi configurati.
        # I due controlli di disponibilita restano raggiungibili per Docker e il precedente inoltro.
        if path not in {"/health", "/ready"}:
            host = headers.get("host", "").lower()
            allowed_hosts = {urlsplit(origin).netloc.lower() for origin in settings.origins}
            if host not in allowed_hosts:
                await reject(400, "Indirizzo non configurato per l'applicazione.")
                return
        mobile = path.startswith("/v1/")
        if mobile and method not in {"GET", "HEAD", "OPTIONS"}:
            if headers.get("origin") and headers["origin"] not in settings.origins:
                await reject(403, "Origine della richiesta non consentita.")
                return
        if (api or mobile) and method not in {"GET", "HEAD", "OPTIONS"}:
            if api and headers.get("x-requested-with") != "Telederm":
                await reject(403, "Richiesta non verificata.")
                return
            origin = headers.get("origin")
            if origin and origin not in settings.origins:
                await reject(403, "Origine della richiesta non consentita.")
                return
            if headers.get("sec-fetch-site") == "cross-site":
                await reject(403, "Richiesta proveniente da un altro sito.")
                return
            # Buffer limitato: blocca anche corpi chunked prima del parser di FastAPI.
            limit = (40 * 1024 * 1024 + 65536) if path == "/v1/submissions" else (settings.max_upload_bytes + 65536 if path.endswith("/images") else 65536)
            try:
                if int(headers.get("content-length", "0")) > limit:
                    await reject(413, "Richiesta troppo grande.")
                    return
            except ValueError:
                await reject(400, "Dimensione della richiesta non valida.")
                return
            chunks, total = [], 0
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                chunk = message.get("body", b"")
                total += len(chunk)
                if total > limit:
                    await reject(413, "Richiesta troppo grande.")
                    return
                chunks.append(chunk)
                if not message.get("more_body", False):
                    break
            body = b"".join(chunks)
            delivered = False

            async def buffered_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()
            next_receive = buffered_receive
        else:
            next_receive = receive

        async def safe_send(message):
            if message["type"] == "http.response.start":
                extra = [
                    (b"x-content-type-options", b"nosniff"),
                    (b"referrer-policy", b"no-referrer"),
                    (b"x-frame-options", b"DENY"),
                    (b"permissions-policy", b"camera=(), microphone=(), geolocation=()"),
                    (b"content-security-policy", b"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"),
                ]
                if api or mobile or path == "/":
                    extra.append((b"cache-control", b"no-store"))
                message["headers"] = list(message.get("headers", [])) + extra
            await send(message)
        await self.app(scope, next_receive, safe_send)
