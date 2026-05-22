import React, { memo, useCallback, useEffect, useState } from 'react'
import {
  FlatList,
  Image,
  Modal,
  Text,
  TouchableOpacity,
  View,
  Dimensions,
  ActivityIndicator,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import PdfThumbnail from 'react-native-pdf-thumbnail'
import { IconSymbol } from '@/components/ui/icon-symbol'

const THUMB_WIDTH = 80
const THUMB_HEIGHT = 110
const COLUMNS = 3
const GAP = 12

interface ThumbnailModalProps {
  visible: boolean
  onClose: () => void
  onSelectPage: (page: number) => void
  filePath: string
  totalPages: number
  currentPage: number
}

const ThumbnailItem = memo(function ThumbnailItem({
  filePath,
  pageIndex,
  pageNumber,
  isCurrentPage,
  onPress,
}: {
  filePath: string
  pageIndex: number
  pageNumber: number
  isCurrentPage: boolean
  onPress: () => void
}) {
  const [thumbnail, setThumbnail] = useState<{ uri: string; width: number; height: number } | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    let cancelled = false
    PdfThumbnail.generate(filePath, pageIndex, 50)
      .then((result) => {
        if (!cancelled) setThumbnail(result)
      })
      .catch(() => {
        if (!cancelled) setError(true)
      })
    return () => { cancelled = true }
  }, [filePath, pageIndex])

  return (
    <TouchableOpacity
      onPress={onPress}
      style={{
        alignItems: 'center',
        padding: GAP / 2,
        width: (Dimensions.get('window').width - GAP * 2) / COLUMNS,
      }}
    >
      {thumbnail ? (
        <Image
          source={{ uri: thumbnail.uri }}
          style={{
            width: THUMB_WIDTH,
            height: THUMB_HEIGHT,
            borderWidth: isCurrentPage ? 2 : 1,
            borderColor: isCurrentPage ? '#3b82f6' : '#d1d5db',
            borderRadius: 4,
          }}
          resizeMode="contain"
        />
      ) : error ? (
        <View style={{
          width: THUMB_WIDTH,
          height: THUMB_HEIGHT,
          backgroundColor: '#fecaca',
          borderRadius: 4,
          justifyContent: 'center',
          alignItems: 'center',
        }}>
          <Text style={{ fontSize: 10, color: '#991b1b' }}>Error</Text>
        </View>
      ) : (
        <View style={{
          width: THUMB_WIDTH,
          height: THUMB_HEIGHT,
          backgroundColor: '#e5e7eb',
          borderRadius: 4,
          justifyContent: 'center',
          alignItems: 'center',
        }}>
          <ActivityIndicator size="small" color="#6b7280" />
        </View>
      )}
      <Text style={{
        fontSize: 11,
        color: isCurrentPage ? '#3b82f6' : '#6b7280',
        marginTop: 4,
        fontWeight: isCurrentPage ? '700' : '400',
      }}>
        {pageNumber}
      </Text>
    </TouchableOpacity>
  )
})

export function ThumbnailModal({
  visible,
  onClose,
  onSelectPage,
  filePath,
  totalPages,
  currentPage,
}: ThumbnailModalProps) {
  const pages = Array.from({ length: totalPages }, (_, i) => i)

  const handleSelect = useCallback((pageNumber: number) => {
    onSelectPage(pageNumber)
    onClose()
  }, [onSelectPage, onClose])

  const renderItem = useCallback(({ item: pageIndex }: { item: number }) => {
    const pageNumber = pageIndex + 1
    return (
      <ThumbnailItem
        filePath={filePath}
        pageIndex={pageIndex}
        pageNumber={pageNumber}
        isCurrentPage={currentPage === pageNumber}
        onPress={() => handleSelect(pageNumber)}
      />
    )
  }, [filePath, currentPage, handleSelect])

  const getItemLayout = useCallback((_: any, index: number) => ({
    length: THUMB_HEIGHT + GAP + 20,
    offset: (THUMB_HEIGHT + GAP + 20) * Math.floor(index / COLUMNS),
    index,
  }), [])

  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={onClose}
    >
      <SafeAreaView style={{ flex: 1, backgroundColor: '#fff' }} edges={['top', 'bottom']}>
        {/* Header */}
        <View style={{
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'space-between',
          paddingHorizontal: 16,
          paddingVertical: 12,
          borderBottomWidth: 1,
          borderBottomColor: '#e5e7eb',
        }}>
          <Text style={{ fontSize: 17, fontWeight: '600' }}>Pages</Text>
          <TouchableOpacity onPress={onClose} hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
            <IconSymbol name="xmark" size={22} color="#000" />
          </TouchableOpacity>
        </View>

        {/* Thumbnail Grid */}
        <FlatList
          data={pages}
          renderItem={renderItem}
          keyExtractor={(item) => String(item)}
          numColumns={COLUMNS}
          contentContainerStyle={{ padding: GAP }}
          getItemLayout={getItemLayout}
          initialScrollIndex={Math.max(0, Math.floor((currentPage - 1) / COLUMNS))}
          windowSize={5}
          maxToRenderPerBatch={9}
          initialNumToRender={12}
        />
      </SafeAreaView>
    </Modal>
  )
}
