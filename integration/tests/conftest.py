import os
import pytest
from playwright.sync_api import sync_playwright

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as p:
        browser = p.chromium.launch()
        yield browser
        browser.close()


@pytest.fixture
def auth_page(browser):
    """Page with a virtual WebAuthn authenticator attached."""
    context = browser.new_context()
    page = context.new_page()

    client = context.new_cdp_session(page)
    client.send("WebAuthn.enable", {"enableUI": False})
    result = client.send(
        "WebAuthn.addVirtualAuthenticator",
        {
            "options": {
                "protocol": "ctap2",
                "transport": "internal",
                "hasResidentKey": True,
                "hasUserVerification": True,
                "isUserVerified": True,
                "automaticPresenceSimulation": True,
            }
        },
    )

    page.auth_cdp = client
    page.auth_id = result["authenticatorId"]
    page.goto(BASE_URL)

    yield page

    context.close()
