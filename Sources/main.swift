if CommandLine.arguments.contains("--selftest") {
    await selftest()
} else {
    ShipyardApp.main()
}
