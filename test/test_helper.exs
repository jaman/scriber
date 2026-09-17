sandbox =
  Path.join([
    System.tmp_dir!(),
    "scriber-test-#{System.system_time(:microsecond)}-#{:erlang.unique_integer([:positive])}"
  ])

System.put_env("SCRIBER_HOME", sandbox)
System.at_exit(fn _status -> File.rm_rf(sandbox) end)

ExUnit.start()
