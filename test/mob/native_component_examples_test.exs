defmodule Mob.NativeComponentExamplesTest do
  use ExUnit.Case, async: true

  # Example component implementations mirroring what community libraries
  # (mob_maps, mob_charts, mob_video, etc.) would ship.
  #
  # Pure-Elixir tests cover mount/render/handle_event/update — no device needed.
  # On-device tests are tagged :on_device and require `mix mob.connect` first;
  # they are excluded from `mix test` and run explicitly before releases.

  # ── MapComponent ─────────────────────────────────────────────────────────────

  defmodule MapComponent do
    use Mob.Component

    def mount(props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:lat, props[:lat] || 0.0)
       |> Mob.Socket.assign(:lon, props[:lon] || 0.0)
       |> Mob.Socket.assign(:zoom, props[:zoom] || 12)
       |> Mob.Socket.assign(:markers, props[:markers] || [])
       |> Mob.Socket.assign(:selected_marker, nil)}
    end

    def render(assigns) do
      %{
        lat: assigns.lat,
        lon: assigns.lon,
        zoom: assigns.zoom,
        markers: assigns.markers,
        selected_marker: assigns.selected_marker
      }
    end

    def handle_event("marker_tapped", %{"id" => id}, socket) do
      {:noreply, Mob.Socket.assign(socket, :selected_marker, id)}
    end

    def handle_event("region_changed", %{"lat" => lat, "lon" => lon, "zoom" => zoom}, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:lat, lat)
       |> Mob.Socket.assign(:lon, lon)
       |> Mob.Socket.assign(:zoom, zoom)}
    end

    def handle_event("map_tapped", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :selected_marker, nil)}
    end
  end

  # ── ChartComponent ───────────────────────────────────────────────────────────

  defmodule ChartComponent do
    use Mob.Component

    @valid_styles [:line, :bar, :pie]

    def mount(props, socket) do
      style = props[:style] || :line

      unless style in @valid_styles do
        raise ArgumentError,
              "ChartComponent: invalid style #{inspect(style)}, " <>
                "expected one of #{inspect(@valid_styles)}"
      end

      {:ok,
       socket
       |> Mob.Socket.assign(:data, props[:data] || [])
       |> Mob.Socket.assign(:style, style)
       |> Mob.Socket.assign(:color, props[:color] || "#007AFF")
       |> Mob.Socket.assign(:selected_index, nil)}
    end

    def render(assigns) do
      %{
        data: assigns.data,
        style: Atom.to_string(assigns.style),
        color: assigns.color,
        selected_index: assigns.selected_index
      }
    end

    def handle_event("segment_tapped", %{"index" => i}, socket) do
      {:noreply, Mob.Socket.assign(socket, :selected_index, i)}
    end

    def handle_event("selection_cleared", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :selected_index, nil)}
    end
  end

  # ── VideoComponent ───────────────────────────────────────────────────────────

  defmodule VideoComponent do
    use Mob.Component

    def mount(props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:url, props[:url])
       |> Mob.Socket.assign(:autoplay, props[:autoplay] || false)
       |> Mob.Socket.assign(:controls, Map.get(props, :controls, true))
       |> Mob.Socket.assign(:playing, props[:autoplay] || false)
       |> Mob.Socket.assign(:position, 0.0)
       |> Mob.Socket.assign(:duration, nil)}
    end

    def render(assigns) do
      %{
        url: assigns.url,
        autoplay: assigns.autoplay,
        controls: assigns.controls,
        playing: assigns.playing
      }
    end

    def handle_event("play", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :playing, true)}
    end

    def handle_event("pause", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :playing, false)}
    end

    def handle_event("ended", _payload, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:playing, false)
       |> Mob.Socket.assign(:position, 0.0)}
    end

    def handle_event("time_update", %{"position" => pos, "duration" => dur}, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:position, pos)
       |> Mob.Socket.assign(:duration, dur)}
    end

    def handle_event("error", %{"message" => _msg}, socket) do
      {:noreply, Mob.Socket.assign(socket, :playing, false)}
    end
  end

  # ── PDFComponent ─────────────────────────────────────────────────────────────

  defmodule PDFComponent do
    use Mob.Component

    def mount(props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:url, props[:url])
       |> Mob.Socket.assign(:current_page, 1)
       |> Mob.Socket.assign(:total_pages, nil)}
    end

    def render(assigns) do
      %{
        url: assigns.url,
        current_page: assigns.current_page,
        total_pages: assigns.total_pages
      }
    end

    def handle_event("page_changed", %{"page" => page, "total" => total}, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:current_page, page)
       |> Mob.Socket.assign(:total_pages, total)}
    end

    def handle_event("document_loaded", %{"total" => total}, socket) do
      {:noreply, Mob.Socket.assign(socket, :total_pages, total)}
    end
  end

  # ── ARComponent ──────────────────────────────────────────────────────────────

  defmodule ARComponent do
    use Mob.Component

    def mount(props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:model_url, props[:model_url])
       |> Mob.Socket.assign(:enable_coaching, Map.get(props, :enable_coaching, true))
       |> Mob.Socket.assign(:tracking_ready, false)
       |> Mob.Socket.assign(:planes_detected, 0)
       |> Mob.Socket.assign(:tap_position, nil)}
    end

    def render(assigns) do
      %{
        model_url: assigns.model_url,
        enable_coaching: assigns.enable_coaching,
        tracking_ready: assigns.tracking_ready,
        planes_detected: assigns.planes_detected
      }
    end

    def handle_event("tracking_ready", _payload, socket) do
      {:noreply, Mob.Socket.assign(socket, :tracking_ready, true)}
    end

    def handle_event("plane_detected", %{"count" => n}, socket) do
      {:noreply, Mob.Socket.assign(socket, :planes_detected, n)}
    end

    def handle_event("tap_in_world", %{"x" => x, "y" => y, "z" => z}, socket) do
      {:noreply, Mob.Socket.assign(socket, :tap_position, %{x: x, y: y, z: z})}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp new_socket(module), do: Mob.Socket.new(module, platform: :no_render)

  defp mount!(module, props) do
    {:ok, socket} = module.mount(props, new_socket(module))
    socket
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # MapComponent
  # ═════════════════════════════════════════════════════════════════════════════

  describe "MapComponent mount/2" do
    test "defaults lat/lon/zoom when not provided" do
      socket = mount!(MapComponent, %{})
      assert socket.assigns.lat == 0.0
      assert socket.assigns.lon == 0.0
      assert socket.assigns.zoom == 12
    end

    test "accepts lat/lon/zoom from props" do
      socket = mount!(MapComponent, %{lat: 43.65, lon: -79.38, zoom: 15})
      assert socket.assigns.lat == 43.65
      assert socket.assigns.lon == -79.38
      assert socket.assigns.zoom == 15
    end

    test "defaults markers to empty list and selected_marker to nil" do
      socket = mount!(MapComponent, %{})
      assert socket.assigns.markers == []
      assert socket.assigns.selected_marker == nil
    end

    test "accepts markers list from props" do
      markers = [%{id: "a", lat: 43.65, lon: -79.38, title: "Union"}]
      socket = mount!(MapComponent, %{markers: markers})
      assert socket.assigns.markers == markers
    end
  end

  describe "MapComponent render/1" do
    test "includes all expected keys" do
      socket = mount!(MapComponent, %{lat: 43.65, lon: -79.38, zoom: 14})
      props = MapComponent.render(socket.assigns)

      assert Map.keys(props) |> Enum.sort() ==
               [:lat, :lon, :markers, :selected_marker, :zoom]
    end

    test "reflects current state" do
      socket = mount!(MapComponent, %{lat: 43.65, lon: -79.38, zoom: 14})
      props = MapComponent.render(socket.assigns)
      assert props.lat == 43.65
      assert props.lon == -79.38
      assert props.zoom == 14
    end
  end

  describe "MapComponent handle_event/3" do
    test "marker_tapped sets selected_marker" do
      socket = mount!(MapComponent, %{})
      {:noreply, updated} = MapComponent.handle_event("marker_tapped", %{"id" => "pin1"}, socket)
      assert updated.assigns.selected_marker == "pin1"
    end

    test "region_changed updates lat/lon/zoom" do
      socket = mount!(MapComponent, %{lat: 0.0, lon: 0.0, zoom: 12})

      {:noreply, updated} =
        MapComponent.handle_event(
          "region_changed",
          %{"lat" => 48.85, "lon" => 2.35, "zoom" => 16},
          socket
        )

      assert updated.assigns.lat == 48.85
      assert updated.assigns.lon == 2.35
      assert updated.assigns.zoom == 16
    end

    test "map_tapped clears selected_marker" do
      socket = mount!(MapComponent, %{})
      socket = Mob.Socket.assign(socket, :selected_marker, "pin1")
      {:noreply, updated} = MapComponent.handle_event("map_tapped", %{}, socket)
      assert updated.assigns.selected_marker == nil
    end
  end

  describe "MapComponent update/2" do
    test "update re-mounts with new props" do
      socket = mount!(MapComponent, %{lat: 0.0, lon: 0.0})
      {:ok, updated} = MapComponent.update(%{lat: 51.5, lon: -0.12}, socket)
      assert updated.assigns.lat == 51.5
      assert updated.assigns.lon == -0.12
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # ChartComponent
  # ═════════════════════════════════════════════════════════════════════════════

  describe "ChartComponent mount/2" do
    test "defaults style to :line and color to blue" do
      socket = mount!(ChartComponent, %{})
      assert socket.assigns.style == :line
      assert socket.assigns.color == "#007AFF"
    end

    test "accepts :bar and :pie styles" do
      assert mount!(ChartComponent, %{style: :bar}).assigns.style == :bar
      assert mount!(ChartComponent, %{style: :pie}).assigns.style == :pie
    end

    test "raises on invalid style" do
      assert_raise ArgumentError, ~r/invalid style/, fn ->
        mount!(ChartComponent, %{style: :radar})
      end
    end

    test "accepts data and custom color" do
      data = [%{x: 1, y: 10}, %{x: 2, y: 20}]
      socket = mount!(ChartComponent, %{data: data, color: "#FF3B30"})
      assert socket.assigns.data == data
      assert socket.assigns.color == "#FF3B30"
    end

    test "selected_index starts nil" do
      socket = mount!(ChartComponent, %{})
      assert socket.assigns.selected_index == nil
    end
  end

  describe "ChartComponent render/1" do
    test "serialises style atom as string for native side" do
      socket = mount!(ChartComponent, %{style: :bar})
      assert ChartComponent.render(socket.assigns).style == "bar"
    end

    test "includes all expected keys" do
      socket = mount!(ChartComponent, %{})
      props = ChartComponent.render(socket.assigns)

      assert Map.keys(props) |> Enum.sort() ==
               [:color, :data, :selected_index, :style]
    end
  end

  describe "ChartComponent handle_event/3" do
    test "segment_tapped records selected index" do
      socket = mount!(ChartComponent, %{data: [1, 2, 3]})
      {:noreply, updated} = ChartComponent.handle_event("segment_tapped", %{"index" => 1}, socket)
      assert updated.assigns.selected_index == 1
    end

    test "selection_cleared resets to nil" do
      socket = mount!(ChartComponent, %{})
      socket = Mob.Socket.assign(socket, :selected_index, 2)
      {:noreply, updated} = ChartComponent.handle_event("selection_cleared", %{}, socket)
      assert updated.assigns.selected_index == nil
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # VideoComponent
  # ═════════════════════════════════════════════════════════════════════════════

  describe "VideoComponent mount/2" do
    test "stores url from props" do
      socket = mount!(VideoComponent, %{url: "https://example.com/clip.mp4"})
      assert socket.assigns.url == "https://example.com/clip.mp4"
    end

    test "autoplay defaults to false and playing mirrors it" do
      socket = mount!(VideoComponent, %{url: "x"})
      assert socket.assigns.autoplay == false
      assert socket.assigns.playing == false
    end

    test "autoplay true sets playing true" do
      socket = mount!(VideoComponent, %{url: "x", autoplay: true})
      assert socket.assigns.autoplay == true
      assert socket.assigns.playing == true
    end

    test "controls defaults to true" do
      assert mount!(VideoComponent, %{url: "x"}).assigns.controls == true
    end

    test "controls can be explicitly disabled" do
      socket = mount!(VideoComponent, %{url: "x", controls: false})
      assert socket.assigns.controls == false
    end

    test "position starts at 0.0 and duration nil" do
      socket = mount!(VideoComponent, %{url: "x"})
      assert socket.assigns.position == 0.0
      assert socket.assigns.duration == nil
    end
  end

  describe "VideoComponent render/1" do
    test "does not expose position or duration to native (managed internally)" do
      socket = mount!(VideoComponent, %{url: "x"})
      props = VideoComponent.render(socket.assigns)
      refute Map.has_key?(props, :position)
      refute Map.has_key?(props, :duration)
    end

    test "includes url, autoplay, controls, playing" do
      socket = mount!(VideoComponent, %{url: "x", autoplay: true})
      props = VideoComponent.render(socket.assigns)
      assert props.url == "x"
      assert props.playing == true
    end
  end

  describe "VideoComponent handle_event/3" do
    test "play sets playing true" do
      socket = mount!(VideoComponent, %{url: "x"})
      {:noreply, updated} = VideoComponent.handle_event("play", %{}, socket)
      assert updated.assigns.playing == true
    end

    test "pause sets playing false" do
      socket = mount!(VideoComponent, %{url: "x", autoplay: true})
      {:noreply, updated} = VideoComponent.handle_event("pause", %{}, socket)
      assert updated.assigns.playing == false
    end

    test "ended resets playing and position" do
      socket = mount!(VideoComponent, %{url: "x", autoplay: true})
      socket = Mob.Socket.assign(socket, :position, 42.0)
      {:noreply, updated} = VideoComponent.handle_event("ended", %{}, socket)
      assert updated.assigns.playing == false
      assert updated.assigns.position == 0.0
    end

    test "time_update tracks position and duration" do
      socket = mount!(VideoComponent, %{url: "x"})

      {:noreply, updated} =
        VideoComponent.handle_event(
          "time_update",
          %{"position" => 12.5, "duration" => 180.0},
          socket
        )

      assert updated.assigns.position == 12.5
      assert updated.assigns.duration == 180.0
    end

    test "error stops playback" do
      socket = mount!(VideoComponent, %{url: "x", autoplay: true})
      {:noreply, updated} = VideoComponent.handle_event("error", %{"message" => "404"}, socket)
      assert updated.assigns.playing == false
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # PDFComponent
  # ═════════════════════════════════════════════════════════════════════════════

  describe "PDFComponent mount/2" do
    test "stores url and starts at page 1" do
      socket = mount!(PDFComponent, %{url: "https://example.com/doc.pdf"})
      assert socket.assigns.url == "https://example.com/doc.pdf"
      assert socket.assigns.current_page == 1
      assert socket.assigns.total_pages == nil
    end
  end

  describe "PDFComponent render/1" do
    test "includes url, current_page, total_pages" do
      socket = mount!(PDFComponent, %{url: "x"})
      props = PDFComponent.render(socket.assigns)
      assert Map.keys(props) |> Enum.sort() == [:current_page, :total_pages, :url]
    end
  end

  describe "PDFComponent handle_event/3" do
    test "document_loaded sets total_pages" do
      socket = mount!(PDFComponent, %{url: "x"})
      {:noreply, updated} = PDFComponent.handle_event("document_loaded", %{"total" => 42}, socket)
      assert updated.assigns.total_pages == 42
    end

    test "page_changed updates current page and total" do
      socket = mount!(PDFComponent, %{url: "x"})

      {:noreply, updated} =
        PDFComponent.handle_event("page_changed", %{"page" => 5, "total" => 20}, socket)

      assert updated.assigns.current_page == 5
      assert updated.assigns.total_pages == 20
    end

    test "page_changed is idempotent on current page" do
      socket = mount!(PDFComponent, %{url: "x"})

      {:noreply, s1} =
        PDFComponent.handle_event("page_changed", %{"page" => 3, "total" => 10}, socket)

      {:noreply, s2} =
        PDFComponent.handle_event("page_changed", %{"page" => 3, "total" => 10}, s1)

      assert s2.assigns.current_page == 3
    end
  end

  describe "PDFComponent update/2" do
    test "switching url resets page to 1" do
      socket = mount!(PDFComponent, %{url: "doc1.pdf"})
      socket = Mob.Socket.assign(socket, :current_page, 7)
      {:ok, updated} = PDFComponent.update(%{url: "doc2.pdf"}, socket)
      assert updated.assigns.url == "doc2.pdf"
      assert updated.assigns.current_page == 1
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # ARComponent
  # ═════════════════════════════════════════════════════════════════════════════

  describe "ARComponent mount/2" do
    test "coaching defaults to enabled, tracking not ready, no planes" do
      socket = mount!(ARComponent, %{model_url: "robot.usdz"})
      assert socket.assigns.enable_coaching == true
      assert socket.assigns.tracking_ready == false
      assert socket.assigns.planes_detected == 0
    end

    test "coaching can be disabled" do
      socket = mount!(ARComponent, %{model_url: "x", enable_coaching: false})
      assert socket.assigns.enable_coaching == false
    end
  end

  describe "ARComponent render/1" do
    test "does not expose tap_position to native" do
      socket = mount!(ARComponent, %{model_url: "x"})
      refute Map.has_key?(ARComponent.render(socket.assigns), :tap_position)
    end

    test "includes model_url, enable_coaching, tracking_ready, planes_detected" do
      socket = mount!(ARComponent, %{model_url: "robot.usdz"})
      props = ARComponent.render(socket.assigns)

      assert Map.keys(props) |> Enum.sort() ==
               [:enable_coaching, :model_url, :planes_detected, :tracking_ready]
    end
  end

  describe "ARComponent handle_event/3" do
    test "tracking_ready flips flag" do
      socket = mount!(ARComponent, %{model_url: "x"})
      {:noreply, updated} = ARComponent.handle_event("tracking_ready", %{}, socket)
      assert updated.assigns.tracking_ready == true
    end

    test "plane_detected updates count" do
      socket = mount!(ARComponent, %{model_url: "x"})
      {:noreply, s1} = ARComponent.handle_event("plane_detected", %{"count" => 1}, socket)
      {:noreply, s2} = ARComponent.handle_event("plane_detected", %{"count" => 3}, s1)
      assert s2.assigns.planes_detected == 3
    end

    test "tap_in_world records position" do
      socket = mount!(ARComponent, %{model_url: "x"})

      {:noreply, updated} =
        ARComponent.handle_event("tap_in_world", %{"x" => 0.5, "y" => 0.0, "z" => -1.2}, socket)

      assert updated.assigns.tap_position == %{x: 0.5, y: 0.0, z: -1.2}
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # Mob.UI.native_view — shared contract for all community components
  # ═════════════════════════════════════════════════════════════════════════════

  describe "Mob.UI.native_view node contract" do
    for module <- [MapComponent, ChartComponent, VideoComponent, PDFComponent, ARComponent] do
      test "#{module} — type is :native_view" do
        node = Mob.UI.native_view(unquote(module), id: :test)
        assert node.type == :native_view
      end

      test "#{module} — props contain module and id" do
        node = Mob.UI.native_view(unquote(module), id: :test)
        assert node.props.module == unquote(module)
        assert node.props.id == :test
      end

      test "#{module} — children is always []" do
        node = Mob.UI.native_view(unquote(module), id: :test)
        assert node.children == []
      end
    end

    test "module name is stable for native registry lookup" do
      node = Mob.UI.native_view(MapComponent, id: :test)
      assert node.props.module == Mob.NativeComponentExamplesTest.MapComponent
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════
  # On-device tests
  # These run against a connected node via Erlang distribution.
  # Prerequisite: `mix mob.connect` in the target app directory.
  # Run with: mix test --only on_device
  # ═════════════════════════════════════════════════════════════════════════════

  @moduletag :on_device

  # The node is read from MOB_TEST_NODE env var, e.g.:
  #   MOB_TEST_NODE="mob_demo_ios@127.0.0.1" mix test --only on_device
  @node String.to_atom(System.get_env("MOB_TEST_NODE", "mob_demo_ios@127.0.0.1"))

  describe "[on_device] ComponentServer lifecycle" do
    test "register_component allocates a non-zero NIF handle" do
      platform = :rpc.call(@node, Application, :get_env, [:mob, :platform, :ios])

      {:ok, pid} =
        :rpc.call(@node, Mob.ComponentServer, :start, [
          [
            module: MapComponent,
            id: :od_map_handle,
            screen_pid: :rpc.call(@node, Process, :whereis, [:mob_screen]),
            props: %{lat: 43.65, lon: -79.38},
            platform: platform
          ]
        ])

      handle = :rpc.call(@node, Mob.ComponentServer, :get_handle, [pid])
      assert is_integer(handle) and handle != 0

      :rpc.call(@node, Process, :exit, [pid, :shutdown])
    end

    test "render_props reflects mounted state" do
      screen_pid = :rpc.call(@node, Process, :whereis, [:mob_screen])

      {:ok, pid} =
        :rpc.call(@node, Mob.ComponentServer, :start, [
          [
            module: ChartComponent,
            id: :od_chart,
            screen_pid: screen_pid,
            props: %{data: [1, 2, 3], style: :bar},
            platform: :no_render
          ]
        ])

      props = :rpc.call(@node, Mob.ComponentServer, :render_props, [pid])
      assert props.style == "bar"
      assert props.data == [1, 2, 3]

      :rpc.call(@node, Process, :exit, [pid, :shutdown])
    end

    test "dispatch/3 delivers event and updates rendered props" do
      screen_pid = :rpc.call(@node, Process, :whereis, [:mob_screen])

      {:ok, pid} =
        :rpc.call(@node, Mob.ComponentServer, :start, [
          [
            module: ChartComponent,
            id: :od_chart_event,
            screen_pid: screen_pid,
            props: %{data: [10, 20, 30]},
            platform: :no_render
          ]
        ])

      :rpc.call(@node, Mob.ComponentServer, :dispatch, [pid, "segment_tapped", %{"index" => 2}])
      # flush mailbox
      :rpc.call(@node, :sys, :get_state, [pid])

      props = :rpc.call(@node, Mob.ComponentServer, :render_props, [pid])
      assert props.selected_index == 2

      :rpc.call(@node, Process, :exit, [pid, :shutdown])
    end

    test "update/2 re-renders with new props" do
      screen_pid = :rpc.call(@node, Process, :whereis, [:mob_screen])

      {:ok, pid} =
        :rpc.call(@node, Mob.ComponentServer, :start, [
          [
            module: MapComponent,
            id: :od_map_update,
            screen_pid: screen_pid,
            props: %{lat: 0.0, lon: 0.0, zoom: 12},
            platform: :no_render
          ]
        ])

      :rpc.call(@node, Mob.ComponentServer, :update, [pid, %{lat: 51.5, lon: -0.12, zoom: 14}])
      :rpc.call(@node, :sys, :get_state, [pid])

      props = :rpc.call(@node, Mob.ComponentServer, :render_props, [pid])
      assert props.lat == 51.5
      assert props.zoom == 14

      :rpc.call(@node, Process, :exit, [pid, :shutdown])
    end

    test "registry deregisters on terminate" do
      screen_pid = :rpc.call(@node, Process, :whereis, [:mob_screen])

      {:ok, pid} =
        :rpc.call(@node, Mob.ComponentServer, :start, [
          [
            module: PDFComponent,
            id: :od_pdf_term,
            screen_pid: screen_pid,
            props: %{url: "test.pdf"},
            platform: :no_render
          ]
        ])

      assert {:ok, ^pid} =
               :rpc.call(@node, Mob.ComponentRegistry, :lookup, [
                 screen_pid,
                 :od_pdf_term,
                 PDFComponent
               ])

      :rpc.call(@node, Process, :exit, [pid, :shutdown])
      Process.sleep(50)

      assert {:error, :not_found} =
               :rpc.call(@node, Mob.ComponentRegistry, :lookup, [
                 screen_pid,
                 :od_pdf_term,
                 PDFComponent
               ])
    end
  end
end
