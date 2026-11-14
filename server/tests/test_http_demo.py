from fastapi.testclient import TestClient
import pytest

from app.config import get_settings
from app.main import app
from tests.conftest import PASSWORD


def configure(monkeypatch, origin, demo='', secure='false'):
    monkeypatch.setenv('APP_ORIGINS',origin)
    monkeypatch.setenv('HTTP_DEMO_ORIGINS',demo)
    monkeypatch.setenv('COOKIE_SECURE',secure)
    get_settings.cache_clear()


def test_network_http_is_disabled_without_explicit_opt_in(environment,monkeypatch):
    configure(monkeypatch,'http://10.50.3.17')
    with pytest.raises(RuntimeError,match='HTTP_DEMO_ORIGINS'):
        get_settings()


def test_http_opt_in_does_not_authorize_other_origins(environment,monkeypatch):
    configure(monkeypatch,'http://10.50.3.17,http://untrusted.invalid','http://10.50.3.17')
    with pytest.raises(RuntimeError,match='HTTP_DEMO_ORIGINS'):
        get_settings()


@pytest.mark.parametrize(('origin','demo','secure'),[
    ('http://10.50.3.17','http://10.50.3.18','false'),
    ('https://telederm.example','https://telederm.example','false'),
    ('http://10.50.3.17','http://10.50.3.17','true'),
    ('https://telederm.example','','false'),
])
def test_inconsistent_http_and_cookie_configuration_rejected(environment,monkeypatch,origin,demo,secure):
    configure(monkeypatch,origin,demo,secure)
    with pytest.raises(RuntimeError):
        get_settings()


def test_https_retains_secure_cookies(environment,monkeypatch):
    configure(monkeypatch,'https://telederm.example',secure='true')
    with TestClient(app,base_url='https://telederm.example') as client:
        response=client.post('/api/login',headers={'Origin':'https://telederm.example','X-Requested-With':'Telederm'},
            json={'username':'paziente.uno','password':PASSWORD})
        assert response.status_code == 200
        assert 'secure' in response.headers['set-cookie'].lower()
        assert client.get('/api/me').status_code == 200


def test_institutional_http_login_and_csrf_remain_protected(environment,monkeypatch):
    origin='http://10.50.3.17'
    configure(monkeypatch,origin,origin)
    with TestClient(app,base_url=origin) as client:
        client.headers.update({'Origin':origin,'X-Requested-With':'Telederm'})
        response=client.post('/api/login',json={'username':'paziente.uno','password':PASSWORD})
        assert response.status_code == 200,response.text
        cookie=response.headers['set-cookie'].lower()
        assert 'httponly' in cookie and 'samesite=strict' in cookie and 'secure' not in cookie
        assert client.get('/api/me').status_code == 200
        client.headers['X-CSRF-Token']=response.json()['csrf_token']
        assert client.post('/api/cases',json={'demo_confirmed':True}).status_code == 201
        assert client.get('/api/status').json()['http_demo'] is True
        assert client.post('/api/cases',json={'demo_confirmed':True},headers={'Origin':'http://193.204.50.163'}).status_code == 403
        assert client.post('/api/cases',json={'demo_confirmed':True},headers={'X-CSRF-Token':'invalid'}).status_code == 403
        assert client.get('/api/cases',headers={'Host':'193.204.50.163'}).status_code == 400
        assert client.get('/',headers={'Host':'193.204.50.163'}).status_code == 400
        assert client.get('/static/app.js',headers={'Host':'untrusted.invalid'}).status_code == 400
        assert client.get('/health',headers={'Host':'193.204.50.163'}).json() == {'status':'ok'}


@pytest.mark.parametrize('origin',['http://10.50.3.17','http://193.204.50.163'])
def test_private_and_public_http_addresses_can_be_authorized_together(environment,monkeypatch,origin):
    origins='http://10.50.3.17,http://193.204.50.163'
    configure(monkeypatch,origins,origins)
    with TestClient(app,base_url=origin) as client:
        client.headers.update({'Origin':origin,'X-Requested-With':'Telederm'})
        assert client.get('/').status_code == 200
        assert client.get('/api/me').status_code == 401
        login=client.post('/api/login',json={'username':'paziente.uno','password':PASSWORD})
        assert login.status_code == 200
        client.headers['X-CSRF-Token']=login.json()['csrf_token']
        assert client.get('/api/me').status_code == 200
        assert client.post('/api/cases',json={'demo_confirmed':True}).status_code == 201
        assert client.get('/',headers={'Host':'untrusted.invalid'}).status_code == 400
        assert client.post('/api/cases',json={'demo_confirmed':True},headers={'Origin':'http://untrusted.invalid'}).status_code == 403
        assert client.post('/api/logout').status_code == 204
