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

#include <thrust/iterator/discard_iterator.h>
#include <thrust/transform.h>
#include <algorithm>
#include <vector>
#include "query/algorithm.h"
#include "query/binder.h"

namespace ares {
class GeoContext {
 protected:
  GeoContext(GeoShapeBatch geoShapes,
             int indexVectorLength,
             uint32_t startCount,
             uint32_t *outputPredicate,
             void *cudaStream)
      : geoShapes(geoShapes),
        indexVectorLength(indexVectorLength),
        startCount(startCount), outputPredicate(outputPredicate),
        cudaStream(reinterpret_cast<cudaStream_t>(cudaStream)) {}
  GeoShapeBatch geoShapes;
  int indexVectorLength;
  uint32_t startCount;
  uint32_t *outputPredicate;
  cudaStream_t cudaStream;
 public:
  cudaStream_t getStream() const {
    return cudaStream;
  }
};

class GeoIntersectionContext : public GeoContext {
 public:
  GeoIntersectionContext(GeoShapeBatch geoShapes,
                         int indexVectorLength,
                         uint32_t startCount,
                         RecordID **recordIDVectors,
                         int numForeignTables,
                         uint32_t *outputPredicate,
                         bool inOrOut,
                         void *cudaStream) : GeoContext(geoShapes,
                                                        indexVectorLength,
                                                        startCount,
                                                        outputPredicate,
                                                        cudaStream),
                                             foreignTableRecordIDVectors(
                                                 recordIDVectors),
                                             numForeignTables(numForeignTables),
                                             inOrOut(inOrOut) {}
  template<typename InputIterator>
  int run(uint32_t *indexVector, InputIterator inputIterator);

 private:
  RecordID **foreignTableRecordIDVectors;
  int numForeignTables;
  bool inOrOut;

  template<typename IndexZipIterator>
  int executeRemoveIf(IndexZipIterator indexZipIterator);
};

class GeoIntersectionJoinContext : public GeoContext {
 public:
  GeoIntersectionJoinContext(GeoShapeBatch geoShapes,
                             DimensionOutputVector dimOut,
                             int indexVectorLength,
                             uint32_t startCount,
                             uint32_t *outputPredicate,
                             void *cudaStream) : GeoContext(geoShapes,
                                                            indexVectorLength,
                                                            startCount,
                                                            outputPredicate,
                                                            cudaStream),
                                                 dimOut(dimOut) {}
  template<typename InputIterator>
  int run(uint32_t *indexVector, InputIterator inputIterator);

 private:
  DimensionOutputVector dimOut;
};

// Base binder class for GeoIntersectionJoinContext and GeoIntersectionContext.
template<typename Context>
class GeoInputVectorBinder : public InputVectorBinderBase<Context, 1, 1> {
  typedef InputVectorBinderBase<Context, 1, 1> super_t;
 protected:
  explicit GeoInputVectorBinder(Context context,
                                std::vector<InputVector> inputVectors,
                                uint32_t *indexVector, uint32_t *baseCounts,
                                uint32_t startCount) : super_t(context,
                                                               inputVectors,
                                                               indexVector,
                                                               baseCounts,
                                                               startCount) {
  }
 public:
  template<typename ...InputIterators>
  int bind(InputIterators... boundInputIterators);
};

// Specialize InputVectorBinder for GeoIntersectionJoinContext.
template<>
class InputVectorBinder<GeoIntersectionJoinContext, 1>
    : public GeoInputVectorBinder<
        GeoIntersectionJoinContext> {
  typedef GeoInputVectorBinder<GeoIntersectionJoinContext> super_t;
 public:
  explicit InputVectorBinder(GeoIntersectionJoinContext context,
                             std::vector<InputVector> inputVectors,
                             uint32_t *indexVector, uint32_t *baseCounts,
                             uint32_t startCount) : super_t(context,
                                                            inputVectors,
                                                            indexVector,
                                                            baseCounts,
                                                            startCount) {
  }
};

// Specialize InputVectorBinder for GeoIntersectionContext.
template<>
class InputVectorBinder<GeoIntersectionContext, 1>
    : public GeoInputVectorBinder<GeoIntersectionContext> {
  typedef GeoInputVectorBinder<GeoIntersectionContext> super_t;
 public:
  explicit InputVectorBinder(GeoIntersectionContext context,
                             std::vector<InputVector> inputVectors,
                             uint32_t *indexVector, uint32_t *baseCounts,
                             uint32_t startCount) : super_t(context,
                                                            inputVectors,
                                                            indexVector,
                                                            baseCounts,
                                                            startCount) {
  }
};

}  // namespace ares

CGoCallResHandle GeoBatchIntersects(
    GeoShapeBatch geoShapes, InputVector points, uint32_t *indexVector,
    int indexVectorLength, uint32_t startCount, RecordID **recordIDVectors,
    int numForeignTables, uint32_t *outputPredicate, bool inOrOut,
    void *cudaStream, int device) {
  CGoCallResHandle resHandle = {0, nullptr};
  try {
#ifdef RUN_ON_DEVICE
    cudaSetDevice(device);
#endif
    ares::GeoIntersectionContext
        ctx(geoShapes, indexVectorLength, startCount,
            recordIDVectors, numForeignTables, outputPredicate, inOrOut,
            cudaStream);
    std::vector<InputVector> inputVectors = {points};
    ares::InputVectorBinder<ares::GeoIntersectionContext, 1>
        binder(ctx, inputVectors, indexVector, nullptr, startCount);
    resHandle.res = reinterpret_cast<void *>(binder.bind());
    CheckCUDAError("GeoBatchIntersects");
    return resHandle;
  } catch (const std::exception &e) {
    std::cerr << "Exception happened when doing GeoBatchIntersects:" << e.what()
              << std::endl;
    resHandle.pStrErr = strdup(e.what());
  }
  return resHandle;
}

CGoCallResHandle GeoBatchIntersectsJoin(
    GeoShapeBatch geoShapes, DimensionOutputVector dimOut,
    InputVector points, uint32_t *indexVector, int indexVectorLength,
    uint32_t startCount, uint32_t *outputPredicate, void *cudaStream,
    int device) {
  CGoCallResHandle resHandle = {nullptr, nullptr};
  try {
#ifdef RUN_ON_DEVICE
    cudaSetDevice(device);
#endif
    ares::GeoIntersectionJoinContext
        ctx(geoShapes, dimOut, indexVectorLength, startCount,
            outputPredicate, cudaStream);
    std::vector<InputVector> inputVectors = {points};
    ares::InputVectorBinder<ares::GeoIntersectionJoinContext, 1>
        binder(ctx, inputVectors, indexVector, nullptr, startCount);
    resHandle.res = reinterpret_cast<void *>(binder.bind());
    CheckCUDAError("GeoIntersectsJoin");
    return resHandle;
  } catch (const std::exception &e) {
    std::cerr << "Exception happened when doing GeoIntersectsJoin:" << e.what()
              << std::endl;
    resHandle.pStrErr = strdup(e.what());
  }
  return resHandle;
}

namespace ares {

template<typename Context>
template<typename ...InputIterators>
int GeoInputVectorBinder<Context>::bind(
    InputIterators... boundInputIterators) {
  InputVector input = super_t::inputVectors[0];
  uint32_t *indexVector = super_t::indexVector;
  uint32_t startCount = super_t::startCount;
  Context context = super_t::context;

  if (input.Type == VectorPartyInput) {
    VectorPartySlice points = input.Vector.VP;
    if (points.DataType != GeoPoint) {
      throw std::invalid_argument(
          "only geo point column are allowed in geo_intersects");
    }

    if (points.BasePtr == nullptr) {
      return 0;
    }

    uint8_t *basePtr = points.BasePtr;
    uint32_t nullsOffset = points.NullsOffset;
    uint32_t valueOffset = points.ValuesOffset;
    uint8_t startingIndex = points.StartingIndex;
    uint8_t stepInBytes = 8;
    uint32_t length = points.Length;
    auto columnIter = make_column_iterator<GeoPointT>(
        indexVector, nullptr, startCount, basePtr, nullsOffset, valueOffset,
        length, stepInBytes, startingIndex);
    return context.run(indexVector, columnIter);
  } else if (input.Type == ForeignColumnInput) {
    DataType dataType = input.Vector.ForeignVP.DataType;

    if (dataType != GeoPoint) {
      throw std::invalid_argument(
          "only geo point column are allowed in geo_intersects");
    }
    // Note: for now foreign vectors are dimension table columns
    // that are not compressed nor pre sliced
    RecordID *recordIDs = input.Vector.ForeignVP.RecordIDs;
    const int32_t numBatches = input.Vector.ForeignVP.NumBatches;
    const int32_t baseBatchID = input.Vector.ForeignVP.BaseBatchID;
    VectorPartySlice *vpSlices = input.Vector.ForeignVP.Batches;
    const int32_t numRecordsInLastBatch =
        input.Vector.ForeignVP.NumRecordsInLastBatch;
    bool hasDefault = input.Vector.ForeignVP.DefaultValue.HasDefault;
    DefaultValue defaultValueStruct = input.Vector.ForeignVP.DefaultValue;
    uint8_t stepInBytes = getStepInBytes(dataType);

    ForeignTableIterator<GeoPointT> *vpIters = prepareForeignTableIterators(
        numBatches,
        vpSlices,
        stepInBytes,
        hasDefault,
        defaultValueStruct.Value.GeoPointVal,
        context.getStream());
    int res =
        context.run(indexVector, RecordIDJoinIterator<GeoPointT>(
            recordIDs,
            numBatches,
            baseBatchID,
            vpIters,
            numRecordsInLastBatch,
            nullptr, 0));
    release(vpIters);
    return res;
  }
  throw std::invalid_argument(
      "Unsupported data type " + std::to_string(__LINE__)
          + "for geo intersection contexts");
}

// GeoRemoveFilter
template<typename Value>
struct GeoRemoveFilter {
  explicit GeoRemoveFilter(GeoPredicateIterator predicates, bool inOrOut)
      : predicates(predicates), inOrOut(inOrOut) {}

  GeoPredicateIterator predicates;
  bool inOrOut;

  __host__ __device__
  bool operator()(const Value &index) {
    return inOrOut == predicates[thrust::get<0>(index)] < 0;
  }
};

// actual function for executing geo filter in batch.
template<typename IndexZipIterator>
int GeoIntersectionContext::executeRemoveIf(IndexZipIterator indexZipIterator) {
  GeoPredicateIterator predIter(outputPredicate, geoShapes.TotalWords);
  GeoRemoveFilter<typename IndexZipIterator::value_type> removeFilter(predIter,
                                                                      inOrOut);
#ifdef RUN_ON_DEVICE
  return thrust::remove_if(thrust::cuda::par.on(cudaStream), indexZipIterator,
                           indexZipIterator + indexVectorLength, removeFilter) -
         indexZipIterator;
#else
  return thrust::remove_if(thrust::host, indexZipIterator,
                           indexZipIterator + indexVectorLength, removeFilter) -
      indexZipIterator;
#endif
}

// run intersection algorithm for points and 1 geoshape, side effect is
// modifying output predicate vector
template<typename InputIterator>
void calculateBatchIntersection(GeoShapeBatch geoShapes,
                                InputIterator geoPoints, uint32_t *indexVector,
                                int indexVectorLength, uint32_t startCount,
                                uint32_t *outputPredicate, bool inOrOut,
                                cudaStream_t cudaStream) {
  auto geoIter = make_geo_batch_intersect_iterator(geoPoints, geoShapes,
                                                   outputPredicate, inOrOut);
  int64_t iterLength = (int64_t) indexVectorLength * geoShapes.TotalNumPoints;

  thrust::for_each(
#ifdef RUN_ON_DEVICE
      thrust::cuda::par.on(reinterpret_cast<cudaStream_t>(cudaStream)),
#else
      thrust::host,
#endif
      geoIter, geoIter + iterLength, VoidFunctor());
}

template<typename InputIterator>
int GeoIntersectionContext::run(uint32_t *indexVector,
                                InputIterator inputIterator) {
  calculateBatchIntersection(geoShapes,
                             inputIterator,
                             indexVector,
                             indexVectorLength,
                             startCount,
                             outputPredicate,
                             inOrOut,
                             cudaStream);

  switch (numForeignTables) {
    case 0: {
      IndexZipIteratorMaker<0> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 1: {
      IndexZipIteratorMaker<1> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 2: {
      IndexZipIteratorMaker<2> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 3: {
      IndexZipIteratorMaker<3> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 4: {
      IndexZipIteratorMaker<4> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 5: {
      IndexZipIteratorMaker<5> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 6: {
      IndexZipIteratorMaker<6> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 7: {
      IndexZipIteratorMaker<7> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    case 8: {
      IndexZipIteratorMaker<8> maker;
      return executeRemoveIf(maker.make(indexVector,
                                        foreignTableRecordIDVectors));
    }
    default:throw std::invalid_argument("only support up to 8 foreign tables");
  }
}

struct is_non_negative {
  __host__ __device__
  bool operator()(const int val) { return val >= 0; }
};

template<typename InputIterator>
int GeoIntersectionJoinContext::run(uint32_t *indexVector,
                                    InputIterator inputIterator) {
  calculateBatchIntersection(geoShapes, inputIterator, indexVector,
                             indexVectorLength, startCount, outputPredicate,
                             true, cudaStream);
  typedef thrust::tuple<int8_t, uint8_t> DimensionOutputIterValue;
  GeoPredicateIterator geoPredicateIter(outputPredicate,
                                        geoShapes.TotalWords);

  auto zippedShapeIndexIter = thrust::make_zip_iterator(thrust::make_tuple(
      geoPredicateIter, thrust::constant_iterator<uint8_t>(1)));

  thrust::transform_if(
#ifdef RUN_ON_DEVICE
      thrust::cuda::par.on(reinterpret_cast<cudaStream_t>(cudaStream)),
#else
      thrust::host,
#endif
      zippedShapeIndexIter, zippedShapeIndexIter + indexVectorLength,
      geoPredicateIter,
      ares::make_dimension_output_iterator<uint8_t>(dimOut.DimValues,
                                                    dimOut.DimNulls),
      thrust::identity<DimensionOutputIterValue>(), is_non_negative());
  return 0;
}

}  // namespace ares
