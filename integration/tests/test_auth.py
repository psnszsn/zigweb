import os
from playwright.sync_api import expect

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")


def test_register_and_login(auth_page):
    page = auth_page

    # Register a new credential
    page.click("#btn-register")
    page.wait_for_selector("#btn-register", state="detached")

    # Verify credential was created
    creds = page.auth_cdp.send(
        "WebAuthn.getCredentials", {"authenticatorId": page.auth_id}
    )
    assert len(creds["credentials"]) == 1

    # Login with that credential
    page.click("#btn-login")
    page.wait_for_url(BASE_URL + "/")

    # Should be authenticated
    expect(page.locator('a[href="/notes"]')).to_be_visible()


def test_login_without_credential_fails(auth_page):
    page = auth_page

    # Try to login without registering first — should stay unauthenticated
    page.click("#btn-login")
    page.wait_for_timeout(1000)

    expect(page.locator("#btn-login")).to_be_visible()


def test_logout_clears_session(auth_page):
    page = auth_page

    # Register + login
    page.click("#btn-register")
    page.wait_for_selector("#btn-register", state="detached")
    page.click("#btn-login")
    page.wait_for_url(BASE_URL + "/")
    expect(page.locator('a[href="/notes"]')).to_be_visible()

    # Logout
    page.goto(BASE_URL + "/auth/logout")
    page.wait_for_url(BASE_URL + "/")

    expect(page.locator("#btn-login")).to_be_visible()


def test_session_persists_across_navigation(auth_page):
    page = auth_page

    # Register + login
    page.click("#btn-register")
    page.wait_for_selector("#btn-register", state="detached")
    page.click("#btn-login")
    page.wait_for_url(BASE_URL + "/")

    # Navigate to notes and back
    page.click('a[href="/notes"]')
    page.wait_for_url(BASE_URL + "/notes")
    page.click('a[href="/"]')
    page.wait_for_url(BASE_URL + "/")

    # Still authenticated
    expect(page.locator('a[href="/notes"]')).to_be_visible()
