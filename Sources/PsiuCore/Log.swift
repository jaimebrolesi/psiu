import os

/// Messages for Console.app (subsystem io.github.jaimebrolesi.psiu), mostly failures that are otherwise silent.
public enum Log {
    public static let core = Logger(subsystem: "io.github.jaimebrolesi.psiu", category: "core")
    public static let app = Logger(subsystem: "io.github.jaimebrolesi.psiu", category: "app")
}
