defmodule SnapBackupOnRemoveTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/snap_backup_on_remove.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "snap_backup_test_#{System.unique_integer([:positive])}")
    snap_data = Path.join(root, "snap_data")
    snap_user_data = Path.join(root, "snap_user_data")
    backup_dir = Path.join(root, "backups")
    extract_dir = Path.join(root, "extract")

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      snap_data: snap_data,
      snap_user_data: snap_user_data,
      backup_dir: backup_dir,
      extract_dir: extract_dir
    }
  end

  defp run_backup(context) do
    env = [
      {"SNAP_DATA", context.snap_data},
      {"SNAP_USER_DATA", context.snap_user_data},
      {"SNAP_NAME", "diode-node"},
      {"BACKUP_DIR", context.backup_dir}
    ]

    System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end

  test "creates tarball with node identity, erl_inetrc, and nodedata", context do
    File.mkdir_p!(Path.join(context.snap_data, "nodedata_prod"))
    File.mkdir_p!(context.snap_user_data)

    File.write!(Path.join(context.snap_user_data, "node"), "diode_node@host.diode\n")

    File.write!(
      Path.join(context.snap_user_data, "erl_inetrc"),
      "{host, {127,0,0,1}, [\"host.diode\", \"diode_node@host.diode\"]}.\n"
    )

    File.write!(Path.join(context.snap_data, "nodedata_prod/wallet.dat"), "wallet-secrets")

    {output, 0} = run_backup(context)
    assert output =~ "wallet backup saved"

    [backup_name] = File.ls!(context.backup_dir)
    assert backup_name =~ ~r/^diode_node_backup_.*\.tar\.gz$/

    backup_path = Path.join(context.backup_dir, backup_name)
    assert File.stat!(backup_path).mode &&& 0o777 == 0o600

    File.mkdir_p!(context.extract_dir)

    {_, 0} =
      System.cmd("tar", ["-xzf", backup_path, "-C", context.extract_dir], stderr_to_stdout: true)

    assert File.read!(Path.join(context.extract_dir, "snap_user_data/node")) ==
             "diode_node@host.diode\n"

    assert File.read!(Path.join(context.extract_dir, "snap_user_data/erl_inetrc")) =~
             "{host, {127,0,0,1}"

    assert File.read!(Path.join(context.extract_dir, "snap_data/nodedata_prod/wallet.dat")) ==
             "wallet-secrets"

    manifest = File.read!(Path.join(context.extract_dir, "manifest.txt"))
    assert manifest =~ "diode-node automatic backup"
    assert manifest =~ context.snap_data
  end

  test "skips backup when no critical data exists", context do
    File.mkdir_p!(context.snap_data)
    File.mkdir_p!(context.snap_user_data)

    {output, 0} = run_backup(context)
    assert output =~ "no critical node data found"
    refute File.exists?(context.backup_dir)
  end

  test "does not fail removal when backup directory is not writable", context do
    File.mkdir_p!(context.snap_user_data)
    File.write!(Path.join(context.snap_user_data, "node"), "diode_node@test.diode\n")

    env = [
      {"SNAP_DATA", context.snap_data},
      {"SNAP_USER_DATA", context.snap_user_data},
      {"SNAP_NAME", "diode-node"},
      {"BACKUP_DIR", "/root/diode-node-backup-should-not-exist"}
    ]

    {output, 0} =
      System.cmd("bash", [@script], env: env, stderr_to_stdout: true)

    assert output =~ "cannot create backup directory"
    assert output =~ "snap saved"
  end
end
