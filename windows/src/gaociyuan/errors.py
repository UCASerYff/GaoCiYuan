"""用户可见错误。消息可以展示，不包含凭据。"""

from __future__ import annotations


class AppError(Exception):
    def __init__(self, message: str, code: str = "invalid"):
        super().__init__(message)
        self.message = message
        self.code = code
