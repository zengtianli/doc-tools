import Foundation

@main struct StateCheck {
    @MainActor static func main() async throws {
        let backend = BackendClient(scriptPath: CommandLine.arguments[1])
        let vm = AppViewModel(backend: backend)
        await vm.loadOps()
        precondition(vm.ops.count == 9)
        for op in vm.ops where op.hasOptions {
            precondition(op.groupedOptions.reduce(0) { $0 + $1.items.count } == op.options.count,
                         "Every backend option must render through the production decoder")
        }
        vm.selectedOpID = "quotes"
        vm.onOpChanged()
        vm.addPaths([CommandLine.arguments[2]])
        vm.optionValues["scope.headers"] = false
        let originalPaths = vm.files
        let task = Task { await vm.run() }
        while !vm.isRunning { await Task.yield() }
        vm.clearFiles()
        vm.addPaths(["/not-a-real-input"])
        vm.remove(originalPaths[0])
        precondition(vm.files == originalPaths, "Inputs cannot change during a running task")
        await vm.run()
        precondition(vm.isRunning, "Duplicate execution must not end the active task")
        await task.value
        precondition(vm.results.count == 1 && vm.results[0].ok)
        precondition(vm.changedOptions["scope.headers"] == "0")
        print("PASS production decoding, option selection, active-task isolation and duplicate execution")
    }
}
