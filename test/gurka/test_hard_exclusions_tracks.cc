#include "gurka.h"
#include "valhalla/worker.h"

#include <gtest/gtest.h>

using namespace valhalla;

namespace {

constexpr double grid_size_meters = 100.;

const std::string ascii_map = R"(
  A----B
  |    |
  C----D
)";

const auto layout = gurka::detail::map_to_coordinates(ascii_map, grid_size_meters);

const gurka::ways ways = {
    {"AB", {{"highway", "track"}}},
    {"AC", {{"highway", "residential"}}},
    {"CD", {{"highway", "residential"}}},
    {"DB", {{"highway", "residential"}}},
};

} // namespace

class ExclusionTestExcludeTracks : public ::testing::Test {
protected:
  static gurka::map map;

  static void SetUpTestSuite() {
    map = gurka::buildtiles(layout, ways, {}, {}, "test/data/hard_exclude_tracks",
                            {{"service_limits.allow_hard_exclusions", "true"}});
  }
};

gurka::map ExclusionTestExcludeTracks::map = {};

TEST_F(ExclusionTestExcludeTracks, ExcludeTracks) {
  const auto without_exclusion = gurka::do_action(valhalla::Options::route, map, {"A", "B"}, "truck",
                                                  {{"/costing_options/truck/use_tracks", "1"},
                                                   {"/costing_options/truck/exclude_tracks", "0"}});
  gurka::assert::raw::expect_path(without_exclusion, {"AB"});

  const auto with_exclusion = gurka::do_action(valhalla::Options::route, map, {"A", "B"}, "truck",
                                               {{"/costing_options/truck/use_tracks", "1"},
                                                {"/costing_options/truck/exclude_tracks", "1"}});
  gurka::assert::raw::expect_path(with_exclusion, {"AC", "CD", "DB"});
}
