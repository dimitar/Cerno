defmodule Cerno.TuningTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Cerno.Tuning

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Cerno.Repo)
    :ok
  end

  describe "stats/0" do
    test "outputs insights and principles sections" do
      output = capture_io(fn -> Tuning.stats() end)
      assert output =~ "Insights"
      assert output =~ "Principles"
      assert output =~ "Contradictions"
      assert output =~ "Clusters"
    end
  end

  describe "insights/1" do
    test "doesn't crash on empty DB" do
      output = capture_io(fn -> Tuning.insights() end)
      assert output =~ "Insights"
    end
  end

  describe "insight/1" do
    test "prints not found for bad ID" do
      output = capture_io(fn -> Tuning.insight(-1) end)
      assert output =~ "not found"
    end
  end

  describe "principles/1" do
    test "doesn't crash on empty DB" do
      output = capture_io(fn -> Tuning.principles() end)
      assert output =~ "Principles"
    end
  end

  describe "principle/1" do
    test "prints not found for bad ID" do
      output = capture_io(fn -> Tuning.principle(-1) end)
      assert output =~ "not found"
    end
  end

  describe "config/0" do
    test "contains promotion and ranking groups" do
      output = capture_io(fn -> Tuning.config() end)
      assert output =~ "promotion"
      assert output =~ "ranking"
    end
  end

  describe "config/1" do
    test "contains threshold keys for promotion" do
      output = capture_io(fn -> Tuning.config(:promotion) end)
      assert output =~ "min_confidence"
    end

    test "contains threshold keys for ranking" do
      output = capture_io(fn -> Tuning.config(:ranking) end)
      assert output =~ "confidence_weight"
    end
  end
end
