/*
 * ComputeGD.cu
 *
 *  Created on: 9 Jul 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#include "FindFeaKernel.h"
#include "../KernelConf.h"
#include "../DevicePredictor.h"
#include "../DevicePredictorHelper.h"
#include "../Splitter/DeviceSplitter.h"
#include "../Splitter/Initiator.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../Memory/dtMemManager.h"
#include "../../DeviceHost/SparsePred/DenseInstance.h"

/**
 * @brief: prediction and compute gradient descent
 */
void DeviceSplitter::ComputeGD(vector<RegTree> &vTree, vector<vector<KeyValue> > &vvInsSparse)
{
	GBDTGPUMemManager manager;
	DevicePredictor pred;
	//get features and store the feature ids in a way that the access is efficient
	DenseInsConverter denseInsConverter(vTree);

	//hash feature id to position id
	int numofUsedFea = denseInsConverter.usedFeaSet.size();
	PROCESS_ERROR(numofUsedFea <= manager.m_maxUsedFeaInTrees);
	int *pHashUsedFea = NULL;
	int *pSortedUsedFea = NULL;
	pred.GetUsedFeature(denseInsConverter.usedFeaSet, pHashUsedFea, pSortedUsedFea);

	//for each tree
	int nNumofTree = vTree.size();
	int nNumofIns = manager.m_numofIns;
	PROCESS_ERROR(nNumofIns > 0);

	//the last learned tree
	int numofNodeOfLastTree = 0;
	TreeNode *pLastTree = NULL;
	DTGPUMemManager treeManager;
	int numofTreeLearnt = treeManager.m_numofTreeLearnt;
	int treeId = numofTreeLearnt - 1;
	pred.GetTreeInfo(pLastTree, numofNodeOfLastTree, treeId);

	//start prediction
	checkCudaErrors(cudaMemset(manager.m_pTargetValue, 0, sizeof(float_point) * nNumofIns));
	if(nNumofTree > 0 && numofUsedFea >0)//numofUsedFea > 0 means the tree has more than one node.
	{
		long long startPos = 0;
		int startInsId = 0;
		long long *pInsStartPos = manager.m_pInsStartPos + startInsId;
		manager.MemcpyDeviceToHost(pInsStartPos, &startPos, sizeof(long long));
	//			cout << "start pos ins" << insId << "=" << startPos << endl;
		float_point *pDevInsValue = manager.m_pdDInsValue + startPos;
		int *pDevFeaId = manager.m_pDFeaId + startPos;
		int *pNumofFea = manager.m_pDNumofFea + startInsId;
		int numofInsToFill = nNumofIns;
		KernelConf conf;
		dim3 dimGridThreadForEachIns;
		conf.ComputeBlock(numofInsToFill, dimGridThreadForEachIns);
		int sharedMemSizeEachIns = 1;

		FillMultiDense<<<dimGridThreadForEachIns, sharedMemSizeEachIns>>>(
											  pDevInsValue, pInsStartPos, pDevFeaId, pNumofFea, manager.m_pdDenseIns,
											  manager.m_pSortedUsedFeaId, manager.m_pHashFeaIdToDenseInsPos,
											  numofUsedFea, startInsId, numofInsToFill);
#if testing
			if(cudaGetLastError() != cudaSuccess)
			{
				cout << "error in FillMultiDense" << endl;
				exit(0);
			}
#endif
	}

	//prediction using the last tree
	if(nNumofTree > 0)
	{
		assert(pLastTree != NULL);
		int numofInsToPre = nNumofIns;
		KernelConf conf;
		dim3 dimGridThreadForEachIns;
		conf.ComputeBlock(numofInsToPre, dimGridThreadForEachIns);
		int sharedMemSizeEachIns = 1;
		PredMultiTarget<<<dimGridThreadForEachIns, sharedMemSizeEachIns>>>(
											  manager.m_pTargetValue, numofInsToPre, pLastTree, manager.m_pdDenseIns,
											  numofUsedFea, manager.m_pHashFeaIdToDenseInsPos, treeManager.m_maxTreeDepth);
#if testing
		if(cudaGetLastError() != cudaSuccess)
		{
			cout << "error in PredTarget" << endl;
			exit(0);
		}
#endif
		//save to buffer
		int threadPerBlock;
		dim3 dimGridThread;
		conf.ConfKernel(nNumofIns, threadPerBlock, dimGridThread);
		SaveToPredBuffer<<<dimGridThread, threadPerBlock>>>(manager.m_pTargetValue, nNumofIns, manager.m_pPredBuffer);
		//update the final prediction
		manager.MemcpyDeviceToDevice(manager.m_pPredBuffer, manager.m_pTargetValue, sizeof(float_point) * nNumofIns);
	}

	if(pHashUsedFea != NULL)
		delete []pHashUsedFea;
	if(pSortedUsedFea != NULL)
		delete []pSortedUsedFea;

	//compute GD
	ComputeGDKernel<<<1, 1>>>(nNumofIns, manager.m_pTargetValue, manager.m_pdTrueTargetValue, manager.m_pGrad, manager.m_pHess);

	//copy splittable nodes to GPU memory
		//SNodeStat, SNIdToBuffId, pBuffIdVec need to be reset.
	manager.Memset(manager.m_pSNodeStat, 0, sizeof(nodeStat) * manager.m_maxNumofSplittable);
	manager.Memset(manager.m_pSNIdToBuffId, -1, sizeof(int) * manager.m_maxNumofSplittable);
	manager.Memset(manager.m_pBuffIdVec, -1, sizeof(int) * manager.m_maxNumofSplittable);
	manager.Memset(manager.m_pNumofBuffId, 0, sizeof(int));
	InitNodeStat<<<1, 1>>>(nNumofIns, manager.m_pGrad, manager.m_pHess,
						   manager.m_pSNodeStat, manager.m_pSNIdToBuffId, manager.m_maxNumofSplittable,
						   manager.m_pBuffIdVec, manager.m_pNumofBuffId);
#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in InitNodeStat" << endl;
		exit(0);
	}
#endif
}

