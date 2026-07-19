defmodule EcsTaskDef.EnvFileTest do
  use ExUnit.Case, async: true

  alias EcsTaskDef.EnvFile

  @tmp System.tmp_dir!()

  defp write!(contents) do
    path = Path.join(@tmp, "envfile-test-#{System.unique_integer([:positive])}.env")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "basic KEY=VALUE pairs" do
    path = write!("FOO=bar\nBAZ=qux\n")
    assert {:ok, %{"FOO" => "bar", "BAZ" => "qux"}, []} = EnvFile.parse(path)
  end

  test "export prefix is accepted and ignored" do
    path = write!("export FOO=bar\n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end

  test "full-line comments and blank lines are skipped" do
    path = write!("# a comment\n\n   \nFOO=bar\n  # indented comment\n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end

  test "value is everything after the first =; may contain =" do
    path = write!("URL=https://x.example/a?b=c=d\n")
    assert {:ok, %{"URL" => "https://x.example/a?b=c=d"}, []} = EnvFile.parse(path)
  end

  test "empty value is legal" do
    path = write!("EMPTY=\n")
    assert {:ok, %{"EMPTY" => ""}, []} = EnvFile.parse(path)
  end

  test "one matching outer quote pair is stripped, no escape processing" do
    path = write!(~s(A="hello world"\nB='single'\nC="unbalanced\nD="keep \\n raw"\n))
    assert {:ok, map, []} = EnvFile.parse(path)
    assert map["A"] == "hello world"
    assert map["B"] == "single"
    assert map["C"] == ~s("unbalanced)
    assert map["D"] == ~s(keep \\n raw)
  end

  test "surrounding whitespace is trimmed from key and value" do
    path = write!("  FOO  =  bar  \n")
    assert {:ok, %{"FOO" => "bar"}, []} = EnvFile.parse(path)
  end

  test "CRLF line endings and a UTF-8 BOM are tolerated" do
    path = write!("﻿" <> "FOO=bar\r\nBAZ=qux\r\n")
    assert {:ok, %{"FOO" => "bar", "BAZ" => "qux"}, []} = EnvFile.parse(path)
  end

  test "duplicate keys: last wins, with a warning naming key and both lines" do
    path = write!("FOO=first\nBAR=x\nFOO=second\n")
    assert {:ok, %{"FOO" => "second", "BAR" => "x"}, [warning]} = EnvFile.parse(path)

    assert warning ==
             "warning: #{path}: duplicate key FOO on lines 1 and 3; using line 3"
  end

  test "line with no = is an error with file:line" do
    path = write!("FOO=ok\nnot a pair\n")
    assert {:error, message} = EnvFile.parse(path)
    assert message =~ "#{path}:2:"
    assert message =~ "no '='"
  end

  test "invalid key is an error with file:line" do
    path = write!("1BAD=value\n")
    assert {:error, message} = EnvFile.parse(path)
    assert message =~ "#{path}:1:"
    assert message =~ "invalid key"
  end

  test "missing file is an error" do
    assert {:error, message} = EnvFile.parse("/nonexistent/nope.env")
    assert message =~ "cannot read env file"
  end

  describe "merge/3" do
    test "file keys absent from process env are extra; present keys are skipped" do
      {extra, warnings} =
        EnvFile.merge(%{"NEW" => "a", "SHADOWED" => "file"}, %{"SHADOWED" => "env"}, ".env")

      assert extra == [{"NEW", "a"}]
      assert [warning] = warnings
      assert warning =~ "SHADOWED is set in both the environment and .env"
      assert warning =~ "using the environment value"
      refute warning =~ "file"
      refute warning =~ "env\""
    end

    test "identical values produce no warning" do
      {extra, warnings} = EnvFile.merge(%{"SAME" => "x"}, %{"SAME" => "x"}, ".env")
      assert extra == []
      assert warnings == []
    end

    test "warnings never contain the differing values" do
      {_, [warning]} =
        EnvFile.merge(%{"SECRET" => "hunter2"}, %{"SECRET" => "hunter3"}, ".env.production")

      refute warning =~ "hunter2"
      refute warning =~ "hunter3"
      assert warning =~ ".env.production"
    end
  end
end
