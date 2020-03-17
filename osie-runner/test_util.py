import pytest

import util


@pytest.mark.parametrize(
    "cmdline,key,value",
    [
        ["a=A", "a", "A"],
        ["a=A b=B", "a", "A"],
        ["aa=AA a=A b=B", "a", "A"],
        ["aa=AA a=A b=B", "a", "A"],
        ["b=B", "a", None],
    ],
)
def test_value_from_kopt(cmdline, key, value):
    got = util.value_from_kopt(cmdline, key)
    assert value == got
