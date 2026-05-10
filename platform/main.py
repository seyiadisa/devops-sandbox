try:
    from .api import app
except ImportError:
    from api import app
