import pytest

# Use auto mode so @pytest.mark.asyncio works without explicit decoration on each test
pytest_plugins = ('pytest_asyncio',)
