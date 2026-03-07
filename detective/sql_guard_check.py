"""Bridge to sql_utils.check_sql_safety for the detective module."""

import sys
import os

sys.path.insert(0, "/opt/mcp")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mcp"))

from sql_utils import check_sql_safety

__all__ = ["check_sql_safety"]
