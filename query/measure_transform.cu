//  Copyright (c) 2017-2018 Uber Technologies, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "query/transform.h"

namespace ares {

template<int NInput, typename FunctorType>
int OutputVectorBinder<NInput, FunctorType>::transformMeasureOutput(
    MeasureOutputVector output) {
  switch (output.DataType) {
    case Int32:
      return transform(
          ares::make_measure_output_iterator(
              reinterpret_cast<int32_t *>(output.Values),
              indexVector, baseCounts,
              output.AggFunc));
    case Uint32:
      return transform(
          ares::make_measure_output_iterator(
              reinterpret_cast<uint32_t *>(output.Values),
              indexVector, baseCounts,
              output.AggFunc));
    case Float32:
      return transform(
          ares::make_measure_output_iterator(
              reinterpret_cast<float_t *>(output.Values),
              indexVector, baseCounts,
              output.AggFunc));
    case Int64:
      return transform(
          ares::make_measure_output_iterator(
              reinterpret_cast<int64_t *>(output.Values),
              indexVector, baseCounts,
              output.AggFunc));
    case Float64:
      return transform(
          ares::make_measure_output_iterator(
              reinterpret_cast<double_t *>(output.Values),
              indexVector, baseCounts,
              output.AggFunc));
    default:
      throw std::invalid_argument(
          "Unsupported data type for MeasureOutput");
  }
}

// explicit instantiations.
template int OutputVectorBinder<1,
                                UnaryFunctorType>::transformMeasureOutput(
    MeasureOutputVector output);

template int OutputVectorBinder<2,
                                BinaryFunctorType>::transformMeasureOutput(
    MeasureOutputVector output);

}  // namespace ares
