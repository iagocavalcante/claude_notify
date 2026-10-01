defmodule ClaudeNotify.ReplyInterpreterTest do
  use ExUnit.Case, async: true

  alias ClaudeNotify.ReplyInterpreter

  @question "Allow Bash(rm -rf /tmp/scratch)?"

  defp config(overrides \\ []) do
    %{
      api_key: "test-key",
      model: "jev-latest",
      min_choice_confidence: 0.9,
      min_lossless: 0.7,
      req_options: [plug: {Req.Test, __MODULE__}]
    }
    |> Map.merge(Map.new(overrides))
  end

  defp stub_answers(answers) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:typesafe_request, conn, Jason.decode!(body)})
      Req.Test.json(conn, %{"model" => "jev-latest", "answers" => answers})
    end)
  end

  test "no API key configured never makes a request and returns :free_text" do
    assert ReplyInterpreter.interpret("sim, pode rodar", @question, [], config(api_key: nil)) ==
             :free_text

    refute_receive {:typesafe_request, _conn, _body}
  end

  test "a confident, lossless choice maps to the response code" do
    stub_answers(%{
      "intent" => %{
        "type" => "choice",
        "choice" => "yes",
        "confidence" => 0.97,
        "probabilities" => %{"yes" => 0.97}
      },
      "lossless" => %{"type" => "noul", "noul" => 0.9}
    })

    assert ReplyInterpreter.interpret("sim, pode rodar", @question, [], config()) == {:ok, "yes"}

    assert_receive {:typesafe_request, conn, _body}
    assert conn.request_path == "/v1/systemone"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
  end

  test "confidence below threshold falls back to :free_text" do
    stub_answers(%{
      "intent" => %{"type" => "choice", "choice" => "yes", "confidence" => 0.6},
      "lossless" => %{"type" => "noul", "noul" => 0.9}
    })

    assert ReplyInterpreter.interpret("i guess sure", @question, [], config()) == :free_text
  end

  test "lossless below threshold falls back to :free_text" do
    stub_answers(%{
      "intent" => %{"type" => "choice", "choice" => "no", "confidence" => 0.95},
      "lossless" => %{"type" => "noul", "noul" => 0.13}
    })

    assert ReplyInterpreter.interpret(
             "nah use the existing helper instead",
             @question,
             [],
             config()
           ) == :free_text
  end

  test "an explicit free_text choice always falls back regardless of confidence" do
    stub_answers(%{
      "intent" => %{"type" => "choice", "choice" => "free_text", "confidence" => 0.99},
      "lossless" => %{"type" => "noul", "noul" => 0.99}
    })

    assert ReplyInterpreter.interpret("why does it need rm -rf?", @question, [], config()) ==
             :free_text
  end

  test "criteria include opt_N per numbered option only when options are present" do
    stub_answers(%{
      "intent" => %{"type" => "choice", "choice" => "opt_2", "confidence" => 0.95},
      "lossless" => %{"type" => "noul", "noul" => 0.9}
    })

    options = [{"1", "Approve"}, {"2", "Deny"}]

    assert ReplyInterpreter.interpret("the second one", @question, options, config()) ==
             {:ok, "opt_2"}

    assert_receive {:typesafe_request, _conn, body}
    criteria = body["questions"]["intent"]["criteria"]

    assert Map.has_key?(criteria, "opt_1")
    assert Map.has_key?(criteria, "opt_2")
    refute Map.has_key?(criteria, "yes")
    refute Map.has_key?(criteria, "no")
    assert Map.has_key?(criteria, "escape")
    assert Map.has_key?(criteria, "free_text")
    assert body["state"]["options"] == ["Approve", "Deny"]
  end

  test "criteria omit opt_N and include yes/no/escape when no options are present" do
    stub_answers(%{
      "intent" => %{"type" => "choice", "choice" => "yes", "confidence" => 0.95},
      "lossless" => %{"type" => "noul", "noul" => 0.9}
    })

    ReplyInterpreter.interpret("sim, pode rodar", @question, [], config())

    assert_receive {:typesafe_request, _conn, body}
    criteria = body["questions"]["intent"]["criteria"]

    refute Enum.any?(criteria, fn {key, _} -> String.starts_with?(key, "opt_") end)
    assert Map.has_key?(criteria, "yes")
    assert Map.has_key?(criteria, "yes_dont_ask")
    assert Map.has_key?(criteria, "no")
    assert Map.has_key?(criteria, "escape")
    assert body["state"]["options"] == []
  end

  test "an HTTP error status falls back to :free_text" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert ReplyInterpreter.interpret("sim, pode rodar", @question, [], config()) == :free_text
  end

  test "a transport error falls back to :free_text" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert ReplyInterpreter.interpret("sim, pode rodar", @question, [], config()) == :free_text
  end
end
