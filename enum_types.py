from enum import IntEnum, StrEnum


class LocationTypeEnum(IntEnum):
    UNKNOWN = 0
    UPPER_RIGHT = 1
    LOWER_RIGHT = 2
    LOWER_LEFT = 3
    UPPER_LEFT = 4
    CENTRAL_CROSS = 5


class DistractorTypeEnum(IntEnum):
    UNKNOWN = 0
    TARGET = 1
    DIFFICULT = 2
    EASY = 3


class SearchDifficultyTypeEnum(StrEnum):
    UNKNOWN = "unknown"
    EASY = "easy"
    DIFFICULT = "difficult"
    MIXED = "mixed"


class CueSizeTypeEnum(IntEnum):
    UNKNOWN = 0
    SMALL = 1
    LARGE = 2


class SideTypeEnum(IntEnum):
    UNKNOWN = 0
    LEFT = 1
    RIGHT = 2
