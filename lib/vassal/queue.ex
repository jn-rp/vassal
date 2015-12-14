defmodule Vassal.Queue do
  @moduledoc """
  Implements all the actions for a Queue using the various other components.
  """
  use GenServer

  alias Vassal.QueueStore

  alias Vassal.Queue.QueueMessages
  alias Vassal.Queue.Receiver
  alias Vassal.Queue.ReceiptHandles

  alias Vassal.Actions.CreateQueue
  alias Vassal.Actions.GetQueueUrl
  alias Vassal.Actions.SendMessage
  alias Vassal.Actions.ReceiveMessage
  alias Vassal.Actions.DeleteMessage
  alias Vassal.Actions.ChangeMessageVisibility
  alias Vassal.Actions.DeleteQueue

  alias Vassal.Errors.SQSError
  alias Vassal.Message
  alias Vassal.Utils

  defmodule Config do
    @moduledoc """
    A struct that defines the configuration for a queue.
    """

    defstruct [delay_ms: 0,
               max_message_bytes: 256 * 1024,
               retention_secs: 60 * 60 * 24 * 4,
               recv_wait_time_ms: 0,
               visibility_timeout_ms: 30 * 1000,
               max_retries: nil,
               dead_letter_queue: nil]

    def from_create_queue_attrs(attrs) do
      import Utils, only: [get_param_as_ms: 2, get_param_as_int: 2]

      rv = %{
        delay_ms: get_param_as_ms(attrs, :delay_seconds),
        max_message_bytes: get_param_as_int(attrs, :maximum_message_size),
        retention_secs: get_param_as_int(attrs, :message_retention_period),
        recv_wait_time_ms: get_param_as_ms(attrs,
                                           :receive_message_wait_time_seconds),
        visibility_timeout_ms: get_param_as_ms(attrs, :visibility_timeout)
      }

      defaults = Map.from_struct(%__MODULE__{})
      rv = Dict.merge(rv, defaults, fn(_, v1, v2) -> v1 || v2 end)
      struct(__MODULE__, rv)
    end

  end

  @doc """
  Runs a queue action.
  """
  def run_action(action)

  def run_action(%CreateQueue{queue_name: queue_name, attributes: attrs}) do
    true = QueueStore.add_queue(queue_name,
                                Config.from_create_queue_attrs(attrs))

    {:ok, _pid} = Supervisor.start_child(Vassal.QueueSupervisor, [queue_name])
    %CreateQueue.Result{queue_url: queue_url(queue_name)}
  end

  def run_action(%GetQueueUrl{queue_name: queue_name}) do
    if QueueStore.queue_exists?(queue_name) do
      %GetQueueUrl.Result{queue_url: queue_url(queue_name)}
    else
      raise SQSError, "AWS.SimpleQueueService.NonExistentQueue"
    end
  end

  def run_action(%ReceiveMessage{} = action) do
    receipt_handles = action.queue_name |> ReceiptHandles.for_queue

    unless action.wait_time_ms && action.visibility_timeout_ms do
      config = QueueStore.queue_config(action.queue_name)
      vis_timeout = action.visibility_timeout_ms || config.visibility_timeout_ms
      wait_time = action.wait_time_ms || config.recv_wait_time_ms

      action = %{action | wait_time_ms: wait_time,
                          visibility_timeout_ms: vis_timeout}
    end

    messages =
      action.queue_name
        |> Receiver.for_queue
        |> Receiver.receive_messages(action)
        |> Enum.map(&(recv_message_from_pid &1, receipt_handles, action))
        |> Enum.filter(fn (x) -> x end)

    %ReceiveMessage.Result{messages: messages}
  end

  def run_action(%SendMessage{} = send_message) do
    message_id = UUID.uuid4

    config = QueueStore.queue_config(send_message.queue_name)
    delay_ms = send_message.delay_ms || config.delay_ms

    {:ok, _} = Supervisor.start_child(
      Vassal.Queue.MessageSupervisor.for_queue(send_message.queue_name),
      [%Vassal.Message.MessageInfo{delay_ms: delay_ms,
                                   message_id: message_id,
                                   body: send_message.message_body,
                                   max_retries: config.max_retries,
                                   dead_letter_queue: config.dead_letter_queue}]
    )

    %SendMessage.Result{message_id: message_id, body_md5: "todo"}
  end

  def run_action(%DeleteMessage{} = delete_message) do
    receipt_handles_pid = delete_message.queue_name |> ReceiptHandles.for_queue

    receipt_handles_pid
    |> ReceiptHandles.get_pid_from_handle(delete_message.receipt_handle)
    |> Message.delete_message

    ReceiptHandles.delete_handle(receipt_handles_pid,
                                 delete_message.receipt_handle)

    %DeleteMessage.Result{}
  end

  def run_action(%ChangeMessageVisibility{} = action) do
    action.queue_name
    |> ReceiptHandles.for_queue
    |> ReceiptHandles.get_pid_from_handle(action.receipt_handle)
    |> Message.change_visibility_timeout(action.visibility_timeout_ms)

    %ChangeMessageVisibility.Result{}
  end

  def run_action(%DeleteQueue{} = action) do
    QueueStore.remove_queue(action.queue_name)

    queue_sup = Vassal.Queue.Supervisor.for_queue(action.queue_name)
    :ok = Supervisor.terminate_child(Vassal.QueueSupervisor, queue_sup)

    %DeleteQueue.Result{}
  end

  @attr_conversions %{sent_timestamp: "SentTimestamp",
                      approx_receive_count: "ApproximateReceiveCount",
                      approx_first_receive: "ApproximateFirstReceiveTimestamp"}

  defp recv_message_from_pid(message_pid, receipt_handles_pid, action) do
    message_info = Message.receive_message(message_pid,
                                           action.visibility_timeout_ms)
    if message_info != nil do
      attributes = Enum.map message_info.attributes, fn ({k, v}) ->
        {@attr_conversions[k], v}
      end
      attributes = Enum.into %{}, attributes

      unless "All" in action.attributes do
        attributes = Dict.take(attributes, action.attributes)
      end

      %ReceiveMessage.Message{
        message_id: message_info.message_id,
        receipt_handle: ReceiptHandles.create_receipt(receipt_handles_pid,
                                                      message_pid),
        body_md5: message_info.body_md5,
        body: message_info.body,
        attributes: attributes
      }
    else
      nil
    end
  end

  defp queue_url(queue_name) do
    "#{Application.get_env(:vassal, :url)}/#{queue_name}"
  end
end
