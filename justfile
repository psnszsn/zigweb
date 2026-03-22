gen:
    cd gen && zig build

integration-test *args='':
    nix develop ./integration --command pytest -v integration/tests/ {{ args }}
